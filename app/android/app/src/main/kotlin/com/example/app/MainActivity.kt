package com.example.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.lifecycle.lifecycleScope
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
    private val channel = "io.github.mzsfighters.mam_ai/request_generation"
    private val latestMessageEventChannel = "io.github.mzsfighters.mam_ai/latest_message"
    private lateinit var ragStream: RagStream

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialise the RAG output stream
        ragStream = RagStream(application, lifecycleScope)

        // Two methods can be invoked from dart - one to make the LLM load, and one to get a
        // response to a search query
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
                    val history = (args["history"] as? List<Map<String, String>>) ?: emptyList()
                    val useRetrieval = args["useRetrieval"] as? Boolean ?: true
                    ragStream.generateResponse(prompt, history, useRetrieval)
                    result.success(0)
                }
                "cancelGeneration" -> {
                    ragStream.cancel()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, latestMessageEventChannel).setStreamHandler(ragStream)
    }
}

