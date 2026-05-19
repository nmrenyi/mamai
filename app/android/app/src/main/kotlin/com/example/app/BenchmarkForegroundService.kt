package com.example.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Foreground service that runs the on-device latency benchmark.
 *
 * The service holds a PARTIAL_WAKE_LOCK and posts a sticky notification so
 * the OS keeps the process alive — unlike a plain Activity, which the
 * vendor power manager (e.g. OPPO's OplusProxyWakeLock) will idle as soon
 * as the screen sleeps. This lets multi-hour k-sweeps run while the
 * device is locked or the screen is off.
 *
 * Launched via [BenchmarkActivity] which forwards Intent extras from `am
 * start`. All benchmark logic lives here; the Activity is a thin shim.
 *
 * **Process model.** Both this service and [BenchmarkActivity] declare
 * `android:process=":benchmark"` in the manifest, so they run in a
 * separate process from the main MAM-AI app. That process is fresh on
 * each `am start`: this service constructs its own [RagPipeline]
 * (Gecko + SQLite + LLM load) on entry, independent of any pipeline
 * already loaded in the main app process. Two consequences worth
 * knowing about:
 *
 *  1. The application's `Application` subclass initializes once per
 *     process — anything in your custom Application.onCreate() will
 *     run a second time when the benchmark process spawns.
 *  2. If the main app is also running with the LLM loaded, two LLM
 *     instances may briefly contend for GPU/memory during init.
 *
 * Intent extras (forwarded from the Activity):
 *   repeats:Int                Repetitions per query (default 3)
 *   cooldown_ms:Long           Sleep between runs in ms (default 5000)
 *   skip_retrieval:Boolean     Run No-RAG mode only
 *   rag_only:Boolean           Run RAG mode only
 *                              (skip_retrieval and rag_only are mutually
 *                              exclusive; skip_retrieval wins if both set)
 *   query_filter:String?       Category or specific query ID filter
 *   retrieve_k:Int             Override retrieval top_k for this session.
 *                              Pass -1 (or omit) to use the value from
 *                              runtime_config.json. Any value >= 0 takes
 *                              effect for every query in this run.
 */
class BenchmarkForegroundService : Service() {

    companion object {
        private const val TAG = "mam-ai"
        private const val BENCH_TAG = "mam-ai-bench"
        private const val NOTIFICATION_ID = 1002
        const val CHANNEL_ID = "mam_ai_benchmark"
        private const val DEFAULT_COOLDOWN_MS = 5_000L
        private const val DEFAULT_REPEATS = 3
        private const val CHARS_PER_TOKEN_ESTIMATE = 4.0
    }

    // Dispatchers.Default so the long-running coroutine isn't tied to the UI
    // thread. The service has no UI anyway, but Default also ensures the work
    // continues regardless of any activity lifecycle event.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val executor = Executors.newSingleThreadExecutor()
    private var wakeLock: PowerManager.WakeLock? = null
    // Set once when the first onStartCommand fires runBenchmark. Subsequent
    // intent re-deliveries (e.g. another `am start` before stopSelf() runs)
    // see this true and are no-ops, so we never end up with two concurrent
    // coroutines sharing the executor and the same output JSON.
    @Volatile private var benchmarkStarted = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Promote to foreground FIRST so the wake lock is always paired with
        // a visible notification (Android 12+ enforces this pairing for new
        // foreground-service starts). Acquiring the wake lock in onCreate
        // before startForeground would briefly hold the CPU awake without a
        // notification — and would leak if onStartCommand never ran (e.g.
        // bind-only path or framework deferral).
        startForegroundCompat("MAM-AI benchmark starting…", -1, 0)

        // PARTIAL_WAKE_LOCK lets the CPU keep running through screen-off.
        // Vendor power managers (OPPO ColorOS, Xiaomi MIUI, etc.) respect
        // wake locks held by foreground services — they aggressively
        // release locks held by background activities.
        if (wakeLock == null) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "mam-ai:benchmark"
            ).apply {
                setReferenceCounted(false)
                // 24 h failsafe. Long CPU sweeps (full series × repeats × all k)
                // have already run ~7 h end-to-end; pushing to 24 h leaves
                // plenty of slack so the lock can't silently expire mid-run.
                // If we ever start running sweeps longer than this, switch
                // to a periodic re-acquire instead of bumping further.
                acquire(24L * 60L * 60L * 1000L)
            }
            Log.w(BENCH_TAG, "[BENCHMARK] Foreground started, PARTIAL_WAKE_LOCK acquired")
        }

        // Reject re-deliveries before the benchmark coroutine completes. A
        // second am start while the first is in flight would otherwise spawn
        // a parallel coroutine and clobber the shared RagPipeline / output
        // JSON.
        if (benchmarkStarted) {
            Log.w(BENCH_TAG, "[BENCHMARK] WARNING: ignoring re-delivery; benchmark is already running.")
            return START_NOT_STICKY
        }
        benchmarkStarted = true

        val evalMode = intent?.getBooleanExtra("eval_mode", false) ?: false
        val repeats = intent?.getIntExtra("repeats", DEFAULT_REPEATS) ?: DEFAULT_REPEATS
        val cooldownMs = intent?.getLongExtra("cooldown_ms", DEFAULT_COOLDOWN_MS) ?: DEFAULT_COOLDOWN_MS
        val skipRetrieval = intent?.getBooleanExtra("skip_retrieval", false) ?: false
        val ragOnly = intent?.getBooleanExtra("rag_only", false) ?: false
        val queryFilter = intent?.getStringExtra("query_filter")
        val retrieveKOverride: Int? = intent?.getIntExtra("retrieve_k", -1)?.takeIf { it >= 0 }

        scope.launch {
            try {
                if (evalMode) {
                    runMcqEval()
                } else {
                    runBenchmark(repeats, cooldownMs, skipRetrieval, ragOnly, queryFilter, retrieveKOverride)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "[BENCHMARK] FATAL ERROR: ${t.message}", t)
                Log.w(BENCH_TAG, "[BENCHMARK] FAILED")
            } finally {
                stopSelf()
            }
        }
        // START_NOT_STICKY: don't auto-restart on kill — the benchmark is a
        // one-shot job; restarting halfway through would corrupt the run.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
                Log.w(BENCH_TAG, "[BENCHMARK] Released PARTIAL_WAKE_LOCK")
            }
        }
        wakeLock = null
        scope.cancel()
        // Shut down the single-thread executor that ferries pipeline calls off
        // the coroutine dispatchers. We use shutdownNow() to interrupt the
        // worker thread: scope.cancel() does not propagate cancellation into
        // a blocking native call (e.g. mid-flight LiteRT-LM generation),
        // and a plain shutdown() would return immediately and leave the
        // thread running until the call finishes naturally — keeping the
        // :benchmark process alive after stopForeground.
        executor.shutdownNow()
        // Brief best-effort await so we don't yank the rug if the worker is
        // tearing down cleanly. If it doesn't finish in 2 s we move on; the
        // OS will eventually kill the process anyway.
        try {
            executor.awaitTermination(2, java.util.concurrent.TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        // Use the non-deprecated overload on API 24+ (where it was introduced).
        // The boolean variant has been deprecated since Android 13.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    // ── Notification plumbing ────────────────────────────────────────────

    private fun startForegroundCompat(message: String, progress: Int, max: Int) {
        val notification = buildNotification(this, message, progress, max)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(message: String, progress: Int, max: Int) {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        nm.notify(NOTIFICATION_ID, buildNotification(this, message, progress, max))
    }

    // ── Main benchmark loop ──────────────────────────────────────────────

    private suspend fun runBenchmark(
        repeats: Int,
        cooldownMs: Long,
        skipRetrieval: Boolean,
        ragOnly: Boolean,
        queryFilter: String?,
        retrieveKOverride: Int?,
    ) {
        val benchmarkStart = System.currentTimeMillis()
        val timestamp = SimpleDateFormat("yyyyMMdd'T'HHmmss", Locale.US).format(Date())

        Log.w(BENCH_TAG, "[BENCHMARK] START repeats=$repeats cooldown=${cooldownMs}ms filter=$queryFilter retrieve_k=${retrieveKOverride ?: "default"} rag_only=$ragOnly")

        val deviceInfo = collectDeviceInfo()
        Log.w(BENCH_TAG, "[BENCHMARK] device=${deviceInfo.getString("model")} (${deviceInfo.optString("soc", "?")})")

        updateNotification("Initializing pipeline…", -1, 0)
        Log.w(BENCH_TAG, "[BENCHMARK] Initializing pipeline (Gecko + SQLite)...")
        val initStart = System.currentTimeMillis()
        val pipeline = withContext(executor.asCoroutineDispatcher()) {
            RagPipeline(application)
        }
        val syncInitMs = System.currentTimeMillis() - initStart
        Log.w(BENCH_TAG, "[BENCHMARK] Gecko + SQLite init: ${syncInitMs}ms")

        updateNotification("Loading Gemma 4 LLM…", -1, 0)
        Log.w(BENCH_TAG, "[BENCHMARK] Waiting for LLM model load...")
        val llmWaitStart = System.currentTimeMillis()
        withContext(executor.asCoroutineDispatcher()) { pipeline.awaitLlmReady() }
        val llmInitMs = System.currentTimeMillis() - llmWaitStart
        Log.w(BENCH_TAG, "[BENCHMARK] LLM model loaded: ${llmInitMs}ms (total init: ${System.currentTimeMillis() - initStart}ms)")

        val warmupQueries = listOf(
            "Normal fetal heart rate",
            "Signs of infection after delivery",
            "A mother has heavy bleeding after birth. What should I do first?",
            "A newborn is not breathing after delivery and has a heart rate below 100. What are the first steps to take?",
            "A pregnant woman at 34 weeks has a severe headache, blurred vision, and blood pressure of 160 over 110. The nearest hospital is 45 minutes away. What should I do immediately while waiting for transport?",
        )
        updateNotification("Warmup queries (${warmupQueries.size})…", -1, 0)
        Log.w(BENCH_TAG, "[BENCHMARK] Running ${warmupQueries.size} warmup queries...")
        val warmupStart = System.currentTimeMillis()
        warmupQueries.forEachIndexed { i, prompt ->
            Log.w(BENCH_TAG, "[BENCHMARK] Warmup ${i + 1}/${warmupQueries.size}: \"${prompt.take(40)}...\"")
            withContext(executor.asCoroutineDispatcher()) {
                pipeline.generateResponse(
                    prompt = prompt,
                    history = emptyList(),
                    useRetrieval = false,
                    retrievalListener = {},
                    generationListener = { _, _ -> }
                )
            }
            Log.w(BENCH_TAG, "[BENCHMARK] Warmup ${i + 1} done (${System.currentTimeMillis() - warmupStart}ms elapsed)")
        }
        val warmupMs = System.currentTimeMillis() - warmupStart
        val totalInitMs = System.currentTimeMillis() - initStart
        Log.w(BENCH_TAG, "[BENCHMARK] Init complete: sync=${syncInitMs}ms llm=${llmInitMs}ms warmup=${warmupMs}ms total=${totalInitMs}ms")

        val postInitMemory = collectMemoryInfo()
        delay(cooldownMs)

        val queries = if (queryFilter != null) {
            BenchmarkQueries.ALL.filter { it.category == queryFilter || it.id == queryFilter }
        } else {
            BenchmarkQueries.ALL
        }
        if (queries.isEmpty()) {
            Log.e(BENCH_TAG, "[BENCHMARK] No queries matched filter '$queryFilter'")
            Log.w(BENCH_TAG, "[BENCHMARK] FAILED")
            return
        }

        // skipRetrieval and ragOnly are mutually exclusive. The Python wrapper
        // (benchmark_latency.py) rejects this combination upfront via
        // parser.error(); a direct `am start` could still pass both, so log a
        // visible warning in logcat instead of silently picking one.
        if (skipRetrieval && ragOnly) {
            Log.w(BENCH_TAG, "[BENCHMARK] WARNING: skip_retrieval AND rag_only both set; skip_retrieval wins (No-RAG only).")
        }
        val retrievalModes = when {
            skipRetrieval -> listOf(false)
            ragOnly -> listOf(true)
            else -> listOf(true, false)
        }
        val totalRuns = queries.size * retrievalModes.size * repeats
        Log.w(BENCH_TAG, "[BENCHMARK] Running ${queries.size} queries x ${retrievalModes.size} modes x $repeats repeats = $totalRuns total runs")

        val results = mutableListOf<JSONObject>()
        var runIndex = 0
        val loopStart = System.currentTimeMillis()

        for (query in queries) {
            for (useRetrieval in retrievalModes) {
                for (rep in 1..repeats) {
                    runIndex++
                    updateNotification("[$runIndex/$totalRuns] ${query.id} rep=$rep", runIndex, totalRuns)

                    Log.w(BENCH_TAG, "[BENCHMARK] [$runIndex/$totalRuns] query=${query.id} retrieval=$useRetrieval rep=$rep/$repeats")

                    val preMemory = collectMemoryInfo()
                    val result = runQuery(pipeline, query.text, useRetrieval, retrieveKOverride)
                    val postMemory = collectMemoryInfo()

                    val decodeTps = if (result.decodeMs > 0)
                        round2(result.estimatedTokens / (result.decodeMs / 1000.0))
                    else 0.0

                    val entry = JSONObject().apply {
                        put("query_id", query.id)
                        put("category", query.category)
                        put("query_text", query.text)
                        put("query_word_count", query.wordCount)
                        put("use_retrieval", useRetrieval)
                        put("repetition", rep)
                        put("retrieval_time_ms", result.retrievalTimeMs)
                        put("ttft_ms", result.ttftMs)
                        put("prefill_ms", result.prefillMs)
                        put("decode_ms", result.decodeMs)
                        put("total_generation_ms", result.generationTotalMs)
                        put("total_query_ms", result.totalQueryMs)
                        put("response_length_chars", result.responseChars)
                        put("estimated_tokens", result.estimatedTokens)
                        put("decode_throughput_tps", decodeTps)
                        put("num_retrieved_docs", result.numRetrievedDocs)
                        put("retrieved_chunks", JSONArray().apply {
                            result.retrievedChunks.forEach { doc ->
                                put(JSONObject().apply {
                                    put("text", doc.text)
                                    put("source", doc.source)
                                    put("page", doc.page)
                                    put("chars", doc.text.length)
                                })
                            }
                        })
                        put("retrieved_total_chars", result.retrievedTotalChars)
                        put("response_text", result.responseText)
                        put("error", result.error ?: JSONObject.NULL)
                        put("heap_before_mb", preMemory.getInt("used_mb"))
                        put("heap_after_mb", postMemory.getInt("used_mb"))
                    }
                    results.add(entry)

                    Log.w(BENCH_TAG, "[BENCHMARK] result: ttft=${result.ttftMs}ms decode=${result.decodeMs}ms total=${result.totalQueryMs}ms chars=${result.responseChars} tps=$decodeTps")

                    if (runIndex < totalRuns) {
                        delay(cooldownMs)
                    }
                }
            }
        }

        val output = JSONObject().apply {
            put("benchmark_version", 1)
            put("timestamp", timestamp)
            put("device", deviceInfo)
            put("config", JSONObject().apply {
                put("repeats", repeats)
                put("cooldown_ms", cooldownMs)
                put("skip_retrieval", skipRetrieval)
                put("rag_only", ragOnly)
                put("query_filter", queryFilter ?: JSONObject.NULL)
                put("retrieval_top_k_override", retrieveKOverride ?: JSONObject.NULL)
                // Read model name from the same app_config.json asset the RagPipeline uses,
                // so the JSON metadata reflects whatever model is actually loaded rather than
                // a hardcoded string that goes stale when we switch model artifacts.
                // Wrapped in try/catch: this read runs at the END of the benchmark when we
                // serialize all results — an asset/parse error here would discard 20+ minutes
                // of completed runs that are still in-memory. Better to ship an "unknown" tag
                // and preserve the timing data than lose the whole sweep.
                val llmModelName = try {
                    JSONObject(
                        application.assets.open("app_config.json").bufferedReader().use { it.readText() }
                    ).getString("llm_model")
                } catch (e: Exception) {
                    Log.w("mam-ai-bench", "[BENCHMARK] Failed to read llm_model from app_config.json — recording 'unknown': $e")
                    "unknown"
                }
                put("model", llmModelName)
                // Record the ACTUAL backend the engine initialized on (RagPipeline
                // falls back GPU→CPU if GPU construction or init throws). Reading
                // BuildConfig.USE_GPU_FOR_LLM here would mislabel a silent fallback
                // as the originally-requested backend and make GPU-vs-CPU comparisons
                // invalid. activeBackend is set before llmReady flips true.
                put("backend", pipeline.activeBackend)
                put("mtp_enabled", BuildConfig.USE_MTP_FOR_LLM)
                // Read max_num_tokens + sampler params from runtime_config.json — the same
                // source RagPipeline reads from. Single source of truth, so the JSON metadata
                // can't drift from what the engine actually used.
                try {
                    val rt = JSONObject(application.assets.open("runtime_config.json").bufferedReader().use { it.readText() })
                    put("max_num_tokens", rt.getJSONObject("engine").getInt("max_num_tokens"))
                    val gen = rt.getJSONObject("generation")
                    put("temperature", gen.getDouble("temperature"))
                    put("top_p", gen.getDouble("top_p"))
                    put("top_k", gen.getInt("top_k"))
                } catch (e: Exception) {
                    Log.w("mam-ai-bench", "[BENCHMARK] Failed to read runtime_config.json — recording defaults: $e")
                    put("max_num_tokens", -1)
                    put("temperature", -1.0)
                    put("top_p", -1.0)
                    put("top_k", -1)
                }
                // Artifact fingerprint: SHA-256 of the first 64 KB of the loaded .litertlm.
                // The header (FlatBuffers metadata) lives in the first few KB, so this hash
                // uniquely distinguishes artifact variants — e.g. the default Gemma 4 E4B
                // build from the FP32-tagged rebuild that adds `prefer_activation_type=float32`
                // to the prefill_decode section. Without this, JSON metadata can't tell which
                // .litertlm variant was loaded.
                put("artifact_fingerprint", try {
                    val modelFile = File(application.getExternalFilesDir(null), llmModelName)
                    val buf = ByteArray(65536)
                    val read = modelFile.inputStream().use { it.read(buf) }
                    val digest = MessageDigest.getInstance("SHA-256")
                        .digest(if (read > 0) buf.copyOf(read) else byteArrayOf())
                    digest.joinToString("") { "%02x".format(it) }
                } catch (e: Exception) {
                    Log.w("mam-ai-bench", "[BENCHMARK] Failed to fingerprint artifact: $e")
                    "unknown"
                })
                // Provenance: the git commit SHA that produced this APK. Wired via
                // BuildConfig.GIT_SHA at Gradle build time.
                put("git_commit_sha", BuildConfig.GIT_SHA)
                put("litertlm_version", BuildConfig.LITERTLM_VERSION)
            })
            put("init", JSONObject().apply {
                put("gecko_sqlite_ms", syncInitMs)
                put("llm_load_ms", llmInitMs)
                put("warmup_query_ms", warmupMs)
                put("total_init_ms", totalInitMs)
            })
            put("memory", postInitMemory)
            put("results", JSONArray(results))
            put("total_benchmark_time_ms", System.currentTimeMillis() - benchmarkStart)
        }

        val outFile = File(getExternalFilesDir(null), "benchmark_results.json")
        outFile.writeText(output.toString(2))
        Log.w(BENCH_TAG, "[BENCHMARK] Results written to ${outFile.absolutePath}")
        Log.w(BENCH_TAG, "[BENCHMARK] COMPLETE")
    }

    // ── MCQ eval mode ────────────────────────────────────────────────────

    /**
     * On-device MCQ evaluation runner. Reads a pushed
     * `eval_input.json` ({system_prompt, rows: [{id, user_message}]}),
     * iterates rows through the same LiteRT pipeline production uses,
     * but with the MCQ adapter system prompt and no retrieval. Writes
     * `eval_output.json` ({rows: [{id, response_text, error?}]}) for
     * the harness (run_eval_device.py) to pull and score.
     *
     * Triggered via `am start ... --ez eval_mode true`. Production paths
     * are unreachable from this branch — production chat continues to
     * use the deployed system prompt and the default RAG-injection
     * behaviour.
     */
    private suspend fun runMcqEval() {
        val timestamp = SimpleDateFormat("yyyyMMdd'T'HHmmss", Locale.US).format(Date())
        val evalStart = System.currentTimeMillis()
        Log.w(BENCH_TAG, "[BENCHMARK] START eval_mode=true")

        val inFile = File(getExternalFilesDir(null), "eval_input.json")
        if (!inFile.exists()) {
            Log.e(BENCH_TAG, "[BENCHMARK] eval_input.json not found at ${inFile.absolutePath}")
            Log.w(BENCH_TAG, "[BENCHMARK] FAILED")
            return
        }
        val input = JSONObject(inFile.readText())
        val systemPrompt = input.optString("system_prompt", "")
        if (systemPrompt.isEmpty()) {
            Log.e(BENCH_TAG, "[BENCHMARK] eval_input.json missing 'system_prompt'")
            Log.w(BENCH_TAG, "[BENCHMARK] FAILED")
            return
        }
        val rows = input.getJSONArray("rows")
        Log.w(BENCH_TAG, "[BENCHMARK] eval rows: ${rows.length()}, system_prompt: ${systemPrompt.length} chars")

        updateNotification("Initializing pipeline (eval mode)…", -1, 0)
        Log.w(BENCH_TAG, "[BENCHMARK] Initializing pipeline (Gecko + SQLite)...")
        val initStart = System.currentTimeMillis()
        val pipeline = withContext(executor.asCoroutineDispatcher()) {
            RagPipeline(application)
        }
        val syncInitMs = System.currentTimeMillis() - initStart

        updateNotification("Loading LLM…", -1, 0)
        val llmWaitStart = System.currentTimeMillis()
        withContext(executor.asCoroutineDispatcher()) { pipeline.awaitLlmReady() }
        val llmInitMs = System.currentTimeMillis() - llmWaitStart
        Log.w(BENCH_TAG, "[BENCHMARK] Init complete: sync=${syncInitMs}ms llm=${llmInitMs}ms")

        val out = JSONArray()
        for (i in 0 until rows.length()) {
            val row = rows.getJSONObject(i)
            val id = row.getString("id")
            val userMessage = row.getString("user_message")
            updateNotification("[${i + 1}/${rows.length()}] $id", i + 1, rows.length())
            Log.w(BENCH_TAG, "[BENCHMARK] eval ${i + 1}/${rows.length()} id=$id")

            val t0 = System.currentTimeMillis()
            val response = StringBuilder()
            var error: String? = null
            try {
                withContext(executor.asCoroutineDispatcher()) {
                    pipeline.generateResponse(
                        prompt = userMessage,
                        history = emptyList(),
                        useRetrieval = false,
                        retrievalListener = {},
                        generationListener = { partial, _ -> response.append(partial) },
                        systemInstructionsOverride = systemPrompt,
                        bypassPromptFormatting = true,
                    )
                }
            } catch (e: Exception) {
                error = e.message
                Log.e(BENCH_TAG, "[BENCHMARK] eval row $id failed: ${e.message}", e)
            }
            val elapsedMs = System.currentTimeMillis() - t0

            out.put(JSONObject().apply {
                put("id", id)
                put("response_text", response.toString())
                put("inference_time_ms", elapsedMs)
                put("error", error ?: JSONObject.NULL)
            })
            Log.w(BENCH_TAG, "[BENCHMARK] eval row $id done in ${elapsedMs}ms, ${response.length} chars")
        }

        val output = JSONObject().apply {
            put("eval_version", 1)
            put("timestamp", timestamp)
            put("device", collectDeviceInfo())
            put("n_rows", rows.length())
            put("total_time_ms", System.currentTimeMillis() - evalStart)
            put("rows", out)
        }
        val outFile = File(getExternalFilesDir(null), "eval_output.json")
        outFile.writeText(output.toString(2))
        Log.w(BENCH_TAG, "[BENCHMARK] Results written to ${outFile.absolutePath}")
        Log.w(BENCH_TAG, "[BENCHMARK] COMPLETE")
    }

    // ── Single-query execution ───────────────────────────────────────────

    private data class QueryResult(
        val retrievalTimeMs: Long,
        val ttftMs: Long,
        val prefillMs: Long,
        val decodeMs: Long,
        val generationTotalMs: Long,
        val totalQueryMs: Long,
        val responseChars: Int,
        val estimatedTokens: Int,
        val numRetrievedDocs: Int,
        val retrievedChunks: List<RetrievedDoc>,
        val retrievedTotalChars: Int,
        val responseText: String,
        val error: String?,
    )

    private suspend fun runQuery(
        pipeline: RagPipeline,
        queryText: String,
        useRetrieval: Boolean,
        retrieveKOverride: Int?,
    ): QueryResult {
        var retrievalTimeMs = 0L
        var numDocs = 0
        var firstTokenTime = 0L
        var error: String? = null
        val responseBuilder = StringBuilder()
        var retrievedChunks: List<RetrievedDoc> = emptyList()

        val qStart = System.currentTimeMillis()
        var retrievalDoneTime = 0L

        try {
            withContext(executor.asCoroutineDispatcher()) {
                pipeline.generateResponse(
                    prompt = queryText,
                    history = emptyList(),
                    useRetrieval = useRetrieval,
                    retrievalListener = { docs ->
                        retrievalDoneTime = System.currentTimeMillis()
                        retrievalTimeMs = retrievalDoneTime - qStart
                        numDocs = docs.size
                        retrievedChunks = docs
                    },
                    generationListener = { partial, _ ->
                        responseBuilder.append(partial)
                        if (firstTokenTime == 0L && partial.isNotEmpty()) {
                            firstTokenTime = System.currentTimeMillis()
                        }
                    },
                    retrieveKOverride = retrieveKOverride,
                )
            }
        } catch (e: Exception) {
            error = e.message
            Log.e(BENCH_TAG, "[BENCHMARK] Query failed: ${e.message}", e)
        }

        val qEnd = System.currentTimeMillis()
        val totalQueryMs = qEnd - qStart
        val responseChars = responseBuilder.length

        // TTFT excludes retrieval; we measure from end-of-retrieval to first token.
        val genStart = if (retrievalDoneTime > 0) retrievalDoneTime else qStart
        val ttftMs = if (firstTokenTime > 0) firstTokenTime - genStart else 0
        val decodeMs = if (firstTokenTime > 0) qEnd - firstTokenTime else 0
        val generationTotalMs = qEnd - genStart
        val estimatedTokens = (responseChars / CHARS_PER_TOKEN_ESTIMATE).toInt()

        return QueryResult(
            retrievalTimeMs = retrievalTimeMs,
            ttftMs = ttftMs,
            prefillMs = ttftMs,
            decodeMs = decodeMs,
            generationTotalMs = generationTotalMs,
            totalQueryMs = totalQueryMs,
            responseChars = responseChars,
            estimatedTokens = estimatedTokens,
            numRetrievedDocs = numDocs,
            retrievedChunks = retrievedChunks,
            retrievedTotalChars = retrievedChunks.sumOf { it.text.length },
            responseText = responseBuilder.toString(),
            error = error,
        )
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private fun collectDeviceInfo(): JSONObject = JSONObject().apply {
        put("manufacturer", Build.MANUFACTURER)
        put("model", Build.MODEL)
        put("device", Build.DEVICE)
        put("hardware", Build.HARDWARE)
        put("board", Build.BOARD)
        put("soc", if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else "unknown")
        put("android_version", Build.VERSION.RELEASE)
        put("sdk_int", Build.VERSION.SDK_INT)
        put("abi", Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown")
    }

    private fun collectMemoryInfo(): JSONObject {
        val rt = Runtime.getRuntime()
        return JSONObject().apply {
            put("used_mb", (rt.totalMemory() - rt.freeMemory()) / 1024 / 1024)
            put("free_mb", rt.freeMemory() / 1024 / 1024)
            put("total_mb", rt.totalMemory() / 1024 / 1024)
            put("max_mb", rt.maxMemory() / 1024 / 1024)
        }
    }

    private fun round2(v: Double): Double = Math.round(v * 100.0) / 100.0

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm?.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "MAM-AI Benchmark",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Foreground notification while the on-device latency benchmark runs"
                    setShowBadge(false)
                }
                nm?.createNotificationChannel(channel)
            }
        }
    }

    private fun buildNotification(
        context: Context,
        message: String,
        progress: Int,
        max: Int,
    ): Notification {
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle("MAM-AI Benchmark")
            .setContentText(message)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (max > 0 && progress >= 0) {
            builder.setProgress(max, progress, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }
}
