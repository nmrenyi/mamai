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
                        ragStream.waitForLlmInit()
                        result.success(0)
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
                else -> {
                    result.notImplemented()
                }
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, latestMessageEventChannel).setStreamHandler(ragStream)
    }

    /**
     * Opens a PDF from getExternalFilesDir at the given page using the device's
     * default PDF viewer via FileProvider. The [source] parameter is the filename
     * stem (e.g. "WHO_PositiveBirth_2018"); the file is expected at
     * getExternalFilesDir(null)/WHO_PositiveBirth_2018.pdf.
     *
     * Returns true if an app was found to handle the Intent, false otherwise.
     */
    private fun openPdf(source: String, page: Int): Boolean {
        val baseFolder = application.getExternalFilesDir(null) ?: return false
        val pdfFile = File(baseFolder, "$source.pdf")

        if (!pdfFile.exists()) {
            Log.w("mam-ai", "[PDF] file not found: ${pdfFile.absolutePath}")
            return false
        }

        val uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            pdfFile,
        )

        Log.d("mam-ai", "[PDF] opening $source.pdf at page $page (0-idx=${page - 1})")

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/pdf")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
            // Send both indexing conventions — last putExtra wins for "page".
            // Testing 1-indexed for MuPDF 1.27 (overrides the 0-indexed value).
            putExtra("page", page - 1)        // Adobe Acrobat (0-indexed)
            putExtra("page", page)            // MuPDF 1.27 test (1-indexed, overwrites above)
            putExtra("startPage", page)       // Yozo Office / OPPO reader (1-indexed)
            putExtra("startpage", page)       // lowercase variant
            putExtra("pageNum", page)         // Yozo alternate
            putExtra("PDF_PAGE_NUMBER", page) // Samsung (1-indexed)
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

