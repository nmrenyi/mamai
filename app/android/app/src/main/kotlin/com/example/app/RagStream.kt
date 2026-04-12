package com.example.app

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.LifecycleCoroutineScope
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import kotlin.collections.hashMapOf

/**
 * The eventchannel stream from Android backend <-> Flutter. Flutter subscribes to this to get
 * generation output as it is being generated
 */
class RagStream(application: Application, val lifecycleScope: LifecycleCoroutineScope): EventChannel.StreamHandler {
    private val backgroundExecutor: Executor = Executors.newSingleThreadExecutor()
    // Currently executing generation job - only one query runs at a time
    private var currentJob: Job? = null

    val ragPipeline: RagPipeline by lazy { RagPipeline(application) }

    // Channel sink that sends to flutter
    var latestGeneration: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        requestLlmPreinit()
        this.latestGeneration = events
    }

    override fun onCancel(arguments: Any?) {}

    // Wait for the LLM to initialise
    suspend fun waitForLlmInit() {
        ragPipeline.awaitLlmReady()
    }

    fun requestLlmPreinit() {
        ragPipeline // Force lazy initialization to happen now
    }

    // Cancel any in-progress generation
    fun cancel() {
        synchronized(this) {
            if (currentJob != null) {
                Log.w("mam-ai", "[CANCEL] generation cancelled by user")
                currentJob?.cancel()
                currentJob = null
            }
        }
    }

    // Generate a response to the prompt, sending updates to Flutter as it is being generated
    fun generateResponse(prompt: String, history: List<Map<String, String>>, useRetrieval: Boolean = true, language: String = "en") {
        synchronized(this) {
            if (currentJob != null) {
                currentJob?.cancel()
            }

            currentJob = lifecycleScope.launch {
                withContext(backgroundExecutor.asCoroutineDispatcher()) {
                    // Accumulate tokens so Flutter always receives the full text so far,
                    // not just the latest delta.
                    val accumulatedText = StringBuilder()

                    fun onGenerate(partial: String, done: Boolean) {
                        accumulatedText.append(partial)
                        val fullText = accumulatedText.toString()
                        // We are off the ui thread at the moment. You can only send
                        // messages through event channels while on ui thread.
                        // The `post` puts the sending part back onto the ui thread
                        Handler(Looper.getMainLooper()).post {
                            latestGeneration?.success(hashMapOf("response" to fullText))

                            if (done) {
                                latestGeneration?.success(hashMapOf("done" to true))
                                synchronized(this@RagStream) {
                                    currentJob = null
                                }
                            }
                        }
                    }

                    fun onRetrieve(documents: List<RetrievedDoc>) {
                        Handler(Looper.getMainLooper()).post {
                            latestGeneration?.success(
                                hashMapOf(
                                    "results" to documents.map { doc ->
                                        hashMapOf(
                                            "text" to doc.text,
                                            "source" to doc.source,
                                            "page" to doc.page,
                                        )
                                    }
                                )
                            )
                        }
                    }

                    try {
                        ragPipeline.generateResponse(
                            prompt,
                            history,
                            useRetrieval,
                            language,
                            { results -> onRetrieve(results) },
                            { partial, done -> onGenerate(partial, done) }
                        )
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        // Normal cancellation — don't send error to Flutter,
                        // just clean up. Re-throw so the coroutine framework
                        // handles cancellation properly.
                        synchronized(this@RagStream) {
                            currentJob = null
                        }
                        throw e
                    } catch (e: Exception) {
                        // Send error to Flutter via EventChannel
                        Handler(Looper.getMainLooper()).post {
                            latestGeneration?.error(
                                "LLM_ERROR",
                                e.message ?: "Unknown error during generation",
                                e.stackTraceToString()
                            )
                        }
                        // Clean up state
                        synchronized(this@RagStream) {
                            currentJob = null
                        }
                    }
                }
            }
        }
    }
}
