package com.example.app

import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.lifecycle.lifecycleScope
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File

class MainActivity : FlutterActivity() {
    private val channel = "io.github.mzsfighters.mam_ai/request_generation"
    private val latestMessageEventChannel = "io.github.mzsfighters.mam_ai/latest_message"
    private lateinit var ragStream: RagStream

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialise the RAG output stream
        ragStream = RagStream(application, lifecycleScope)

        // Three methods can be invoked from dart: ensureInit, generateResponse, cancelGeneration
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler {
                call, result ->
            when (call.method) {
                "ensureInit" -> {
                    lifecycleScope.launch {
                        try {
                            ragStream.waitForLlmInit()
                            result.success(0)
                        } catch (t: Throwable) {
                            Log.e("mam-ai", "[ERROR] ensureInit failed", t)
                            result.error(
                                "LLM_INIT_FAILED",
                                t.message ?: "On-device model initialization failed",
                                t.stackTraceToString(),
                            )
                        }
                    }
                }
                "generateResponse" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = call.arguments<Map<String, Any>>()!!
                    val prompt = args["prompt"] as String
                    val history = (args["history"] as? List<*>)?.mapNotNull { item ->
                        (item as? Map<*, *>)?.mapNotNull { (k, v) ->
                            val key = k as? String ?: return@mapNotNull null
                            val value = v as? String ?: return@mapNotNull null
                            key to value
                        }?.toMap()
                    } ?: emptyList()
                    val useRetrieval = args["useRetrieval"] as? Boolean ?: true
                    val language = args["language"] as? String ?: "en"
                    ragStream.generateResponse(prompt, history, useRetrieval, language)
                    result.success(0)
                }
                "cancelGeneration" -> {
                    ragStream.cancel()
                    result.success(null)
                }
                "openPdf" -> {
                    val source = call.argument<String>("source") ?: ""
                    val page = call.argument<Int>("page") ?: 1
                    val opened = openPdf(source, page)
                    result.success(opened)
                }
                "getDeployedRagBundleInfo" -> {
                    result.success(getDeployedRagBundleInfo())
                }
                "getPinnedRagBundleInfo" -> {
                    result.success(getPinnedRagBundleInfo())
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, latestMessageEventChannel).setStreamHandler(ragStream)
    }

    /**
     * Opens a PDF from getExternalFilesDir at the given page using the device's
     * default PDF viewer via FileProvider. The [source] parameter is the raw SOURCE
     * stem from the chunk metadata (e.g. "WHO_Abortion Care_2022"). It is normalized
     * to a safe filename before resolving the file, matching the rule used by
     * package_bundle.py in the mamai-medical-guidelines producer repo:
     *   - replace any char that is not alphanumeric, '-', or '.' with '_'
     *   - collapse consecutive underscores
     *   - strip leading/trailing underscores
     *
     * The file is expected at getExternalFilesDir(null)/<normalizedSource>.pdf.
     * Returns true if an app was found to handle the Intent, false otherwise.
     */
    private fun normalizeSourceId(source: String): String =
        source
            .replace(Regex("[^A-Za-z0-9\\-.]"), "_")
            .replace(Regex("_+"), "_")
            .trim('_')

    private fun getDeployedRagBundleInfo(): Map<String, Any>? {
        val baseFolder = application.getExternalFilesDir(null) ?: return null
        val deployRecord = File(baseFolder, "rag_bundle_deployed.json")

        if (!deployRecord.exists()) {
            return null
        }

        return try {
            val json = JSONObject(deployRecord.readText())
            hashMapOf<String, Any>().apply {
                json.optString("bundle_version").takeIf { it.isNotBlank() }?.let {
                    put("bundleVersion", it)
                }
                json.optString("deployed_at_utc").takeIf { it.isNotBlank() }?.let {
                    put("deployedAtUtc", it)
                }
                json.optString("producer_commit").takeIf { it.isNotBlank() }?.let {
                    put("producerCommit", it)
                }
                json.optString("manifest_sha256").takeIf { it.isNotBlank() }?.let {
                    put("manifestSha256", it)
                }
            }
        } catch (e: Exception) {
            Log.w("mam-ai", "[RAG] failed to read deployed bundle metadata", e)
            null
        }
    }

    private fun getPinnedRagBundleInfo(): Map<String, Any>? =
        try {
            val json = assets.open("rag_assets.lock.json").bufferedReader().use { reader ->
                JSONObject(reader.readText())
            }
            hashMapOf<String, Any>().apply {
                json.optString("bundle_version").takeIf { it.isNotBlank() }?.let {
                    put("bundleVersion", it)
                }
                json.optString("bundle_url").takeIf { it.isNotBlank() }?.let {
                    put("bundleUrl", it)
                }
                json.optString("manifest_sha256").takeIf { it.isNotBlank() }?.let {
                    put("manifestSha256", it)
                }
                json.optString("producer_commit").takeIf { it.isNotBlank() }?.let {
                    put("producerCommit", it)
                }
                json.optInt("source_count").takeIf { it > 0 }?.let {
                    put("sourceCount", it)
                }
                json.optInt("chunk_count").takeIf { it > 0 }?.let {
                    put("chunkCount", it)
                }
            }
        } catch (e: Exception) {
            Log.w("mam-ai", "[RAG] failed to read pinned bundle metadata", e)
            null
        }

    private fun openPdf(source: String, page: Int): Boolean {
        val baseFolder = application.getExternalFilesDir(null) ?: return false
        val normalizedSource = normalizeSourceId(source)
        val safePage = page.coerceAtLeast(1)
        val pdfFile = File(baseFolder, "$normalizedSource.pdf")

        if (!pdfFile.exists()) {
            Log.w("mam-ai", "[PDF] file not found: ${pdfFile.absolutePath}")
            return false
        }

        val uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            pdfFile,
        )

        Log.d("mam-ai", "[PDF] opening $normalizedSource.pdf (source=$source) at page $safePage")

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/pdf")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
            // Keep a single shared "page" extra and add viewer-specific variants.
            putExtra("page", safePage)            // MuPDF / generic 1-indexed test
            putExtra("startPage", safePage)       // Yozo Office / OPPO reader (1-indexed)
            putExtra("startpage", safePage)       // lowercase variant
            putExtra("pageNum", safePage)         // Yozo alternate
            putExtra("PDF_PAGE_NUMBER", safePage) // Samsung (1-indexed)
        }

        return try {
            startActivity(intent)
            true
        } catch (e: android.content.ActivityNotFoundException) {
            Log.w("mam-ai", "[PDF] no PDF viewer app found on device")
            false
        }
    }
}
