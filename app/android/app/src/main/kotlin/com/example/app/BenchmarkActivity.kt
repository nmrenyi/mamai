package com.example.app

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Benchmark activity that runs predefined queries through [RagPipeline]
 * and writes structured timing results to a JSON file on device storage.
 *
 * Launch via ADB:
 *   adb shell am start -n com.example.app/.BenchmarkActivity \
 *       --ei repeats 3 --el cooldown_ms 5000
 *
 * Optional extras:
 *   --ez skip_retrieval true     Skip RAG retrieval (generation only)
 *   --es query_filter short      Filter by category or specific query ID
 */
class BenchmarkActivity : Activity() {

    companion object {
        private const val TAG = "mam-ai"
        private const val BENCH_TAG = "mam-ai-bench"
        private const val DEFAULT_COOLDOWN_MS = 5_000L
        private const val DEFAULT_REPEATS = 3
        private const val CHARS_PER_TOKEN_ESTIMATE = 4.0
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val executor = Executors.newSingleThreadExecutor()
    private lateinit var logView: TextView
    private lateinit var scrollView: ScrollView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Scrollable log console UI
        scrollView = ScrollView(this).apply {
            setBackgroundColor(0xFF000000.toInt())
        }
        logView = TextView(this).apply {
            setTextColor(0xFF00FF00.toInt())
            textSize = 13f
            setPadding(32, 48, 32, 48)
            text = "=== MAM-AI Benchmark ===\n"
        }
        scrollView.addView(logView)
        setContentView(scrollView)

        val repeats = intent.getIntExtra("repeats", DEFAULT_REPEATS)
        val cooldownMs = intent.getLongExtra("cooldown_ms", DEFAULT_COOLDOWN_MS)
        val skipRetrieval = intent.getBooleanExtra("skip_retrieval", false)
        val queryFilter = intent.getStringExtra("query_filter")

        scope.launch {
            try {
                runBenchmark(repeats, cooldownMs, skipRetrieval, queryFilter)
            } catch (t: Throwable) {
                Log.e(TAG, "[BENCHMARK] FATAL ERROR: ${t.message}", t)
                Log.w(BENCH_TAG, "[BENCHMARK] FAILED")
                logStatus("FAILED: ${t.message}")
            } finally {
                finish()
            }
        }
    }

    private fun logStatus(text: String) {
        runOnUiThread {
            logView.append(text + "\n")
            scrollView.post { scrollView.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }

    // ── Main benchmark loop ──────────────────────────────────────────────

    private suspend fun runBenchmark(
        repeats: Int,
        cooldownMs: Long,
        skipRetrieval: Boolean,
        queryFilter: String?,
    ) {
        val benchmarkStart = System.currentTimeMillis()
        val timestamp = SimpleDateFormat("yyyyMMdd'T'HHmmss", Locale.US).format(Date())

        Log.w(BENCH_TAG, "[BENCHMARK] START repeats=$repeats cooldown=${cooldownMs}ms filter=$queryFilter")

        // Device info
        val deviceInfo = collectDeviceInfo()
        Log.w(BENCH_TAG, "[BENCHMARK] device=${deviceInfo.getString("model")} (${deviceInfo.optString("soc", "?")})")

        // Step 1: Gecko + SQLite init (synchronous part of RagPipeline constructor)
        logStatus("Step 1/4: Initializing Gecko embedder + SQLite...")
        Log.w(BENCH_TAG, "[BENCHMARK] Initializing pipeline (Gecko + SQLite)...")
        val initStart = System.currentTimeMillis()
        val pipeline = withContext(executor.asCoroutineDispatcher()) {
            RagPipeline(application)
        }
        val syncInitMs = System.currentTimeMillis() - initStart
        Log.w(BENCH_TAG, "[BENCHMARK] Gecko + SQLite init: ${syncInitMs}ms")
        logStatus("Step 1/4: Gecko + SQLite done (${syncInitMs}ms)")

        // Step 2: Wait for LLM model load (async, started by RagPipeline constructor)
        logStatus("Step 2/4: Loading Gemma 3n LLM model...")
        Log.w(BENCH_TAG, "[BENCHMARK] Waiting for LLM model load...")
        val llmWaitStart = System.currentTimeMillis()
        withContext(executor.asCoroutineDispatcher()) {
            if (!pipeline.llmReady) {
                pipeline.onLlmReady.receive()
            }
        }
        val llmInitMs = System.currentTimeMillis() - llmWaitStart
        Log.w(BENCH_TAG, "[BENCHMARK] LLM model loaded: ${llmInitMs}ms (total init: ${System.currentTimeMillis() - initStart}ms)")
        logStatus("Step 2/4: LLM loaded (${llmInitMs}ms)")

        // Step 3: 5 warmup queries of varying length — warms JIT and LiteRT-LM caches
        val warmupQueries = listOf(
            "Normal fetal heart rate",
            "Signs of infection after delivery",
            "A mother has heavy bleeding after birth. What should I do first?",
            "A newborn is not breathing after delivery and has a heart rate below 100. What are the first steps to take?",
            "A pregnant woman at 34 weeks has a severe headache, blurred vision, and blood pressure of 160 over 110. The nearest hospital is 45 minutes away. What should I do immediately while waiting for transport?",
        )
        logStatus("Step 3/4: Running ${warmupQueries.size} warmup queries...")
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
        Log.w(BENCH_TAG, "[BENCHMARK] Warmup complete: ${warmupMs}ms total (${warmupQueries.size} queries)")
        Log.w(BENCH_TAG, "[BENCHMARK] Init complete: sync=${syncInitMs}ms llm=${llmInitMs}ms warmup=${warmupMs}ms total=${totalInitMs}ms")

        val postInitMemory = collectMemoryInfo()

        // Step 4: Cooldown before timed runs
        logStatus("--- Init summary: gecko=${syncInitMs}ms llm=${llmInitMs}ms warmup=${warmupMs}ms total=${totalInitMs}ms")
        logStatus("Cooldown ${cooldownMs}ms...")
        Thread.sleep(cooldownMs)

        // Filter queries
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

        val retrievalModes = if (skipRetrieval) listOf(false) else listOf(true, false)
        val totalRuns = queries.size * retrievalModes.size * repeats
        Log.w(BENCH_TAG, "[BENCHMARK] Running ${queries.size} queries x ${retrievalModes.size} modes x $repeats repeats = $totalRuns total runs")

        // Execution loop
        val results = mutableListOf<JSONObject>()
        var runIndex = 0
        val loopStart = System.currentTimeMillis()

        for (query in queries) {
            for (useRetrieval in retrievalModes) {
                for (rep in 1..repeats) {
                    runIndex++

                    // Estimate time remaining based on average time per completed run
                    val etaStr = if (runIndex > 1) {
                        val elapsedMs = System.currentTimeMillis() - loopStart
                        val avgPerRun = elapsedMs.toDouble() / (runIndex - 1)
                        val remainingMs = (avgPerRun * (totalRuns - runIndex + 1)).toLong()
                        val remainMin = remainingMs / 60000
                        val remainSec = (remainingMs % 60000) / 1000
                        "ETA: ${remainMin}m ${remainSec}s"
                    } else "ETA: calculating..."

                    Log.w(BENCH_TAG, "[BENCHMARK] [$runIndex/$totalRuns] query=${query.id} retrieval=$useRetrieval rep=$rep/$repeats")
                    logStatus("[$runIndex/$totalRuns] ${query.id} | retrieval=$useRetrieval rep=$rep | $etaStr")

                    val preMemory = collectMemoryInfo()
                    val result = runQuery(pipeline, query.text, useRetrieval)
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
                        put("error", result.error ?: JSONObject.NULL)
                        put("heap_before_mb", preMemory.getInt("used_mb"))
                        put("heap_after_mb", postMemory.getInt("used_mb"))
                    }
                    results.add(entry)

                    val resultLine = "  -> ttft=${result.ttftMs}ms decode=${result.decodeMs}ms total=${result.totalQueryMs}ms tps=$decodeTps"
                    Log.w(BENCH_TAG, "[BENCHMARK] result: ttft=${result.ttftMs}ms decode=${result.decodeMs}ms total=${result.totalQueryMs}ms chars=${result.responseChars} tps=$decodeTps")
                    logStatus(resultLine)

                    val pct = (runIndex * 100) / totalRuns
                    val elapsedMin = (System.currentTimeMillis() - loopStart) / 60000
                    logStatus("  [${"█".repeat(pct / 5)}${"░".repeat(20 - pct / 5)}] $pct% ($elapsedMin min elapsed)")

                    // Cooldown between queries (skip after last run)
                    if (runIndex < totalRuns) {
                        Thread.sleep(cooldownMs)
                    }
                }
            }
        }

        // Assemble output JSON
        val output = JSONObject().apply {
            put("benchmark_version", 1)
            put("timestamp", timestamp)
            put("device", deviceInfo)
            put("config", JSONObject().apply {
                put("repeats", repeats)
                put("cooldown_ms", cooldownMs)
                put("skip_retrieval", skipRetrieval)
                put("query_filter", queryFilter ?: JSONObject.NULL)
                put("model", "gemma-4-E4B-it.litertlm")
                put("backend", "CPU")
                put("max_tokens", 32000)
                put("temperature", 1.0)
                put("top_p", 0.95)
                put("top_k", 64)
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

        // Write to file
        val outFile = File(getExternalFilesDir(null), "benchmark_results.json")
        outFile.writeText(output.toString(2))
        Log.w(BENCH_TAG, "[BENCHMARK] Results written to ${outFile.absolutePath}")
        Log.w(BENCH_TAG, "[BENCHMARK] COMPLETE")
        logStatus("COMPLETE\nResults written to:\n${outFile.absolutePath}")
    }

    // ── Single query execution ───────────────────────────────────────────

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
        val error: String?,
    )

    private suspend fun runQuery(pipeline: RagPipeline, queryText: String, useRetrieval: Boolean): QueryResult {
        var retrievalTimeMs = 0L
        var numDocs = 0
        var firstTokenTime = 0L
        var error: String? = null
        val responseBuilder = StringBuilder()

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
                    },
                    generationListener = { partial, _ ->
                        responseBuilder.append(partial)
                        if (firstTokenTime == 0L && partial.isNotEmpty()) {
                            firstTokenTime = System.currentTimeMillis()
                        }
                    }
                )
            }
        } catch (e: Exception) {
            error = e.message
            Log.e(TAG, "[BENCHMARK] Query failed: ${e.message}", e)
        }

        val qEnd = System.currentTimeMillis()
        val totalQueryMs = qEnd - qStart
        val responseChars = responseBuilder.length

        // Generation timing — measure from after retrieval (or query start if no retrieval)
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
}
