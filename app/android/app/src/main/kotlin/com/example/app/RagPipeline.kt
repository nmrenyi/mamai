package com.example.app

import android.app.Application
import android.content.Context
import android.util.Log
import com.google.ai.edge.localagents.rag.memory.DefaultSemanticTextMemory
import com.google.ai.edge.localagents.rag.memory.SqliteVectorStore
import com.google.ai.edge.localagents.rag.models.Embedder
import com.google.ai.edge.localagents.rag.models.GeckoEmbeddingModel
import com.google.ai.edge.localagents.rag.retrieval.RetrievalConfig
import com.google.ai.edge.localagents.rag.retrieval.RetrievalConfig.TaskType
import com.google.ai.edge.localagents.rag.retrieval.RetrievalRequest
import com.google.common.collect.ImmutableList
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.SamplerConfig
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.guava.await
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.Optional
import org.json.JSONObject
import java.util.concurrent.Executors
import kotlin.jvm.optionals.getOrNull

/** A retrieved document chunk with its source metadata. */
data class RetrievedDoc(
    val text: String,   // chunk body, with [SOURCE|PAGE] prefix stripped
    val source: String, // filename stem, e.g. "WHO_PositiveBirth_2018"
    val page: Int,      // PDF page number
)

/** The RAG pipeline for LLM generation. */
class RagPipeline(application: Application) {
    private val baseFolder = application.getExternalFilesDir(null).toString() + "/"

    // Load system prompts and runtime config from assets.
    // Single source of truth shared with evaluation/ — crashes immediately (IOException)
    // if any asset file is missing from the APK.
    private val systemInstructionsEn: String =
        application.assets.open("system_en.txt").bufferedReader().use { it.readText() }
    private val systemInstructionsSw: String =
        application.assets.open("system_sw.txt").bufferedReader().use { it.readText() }
    private val runtimeConfig: JSONObject =
        JSONObject(application.assets.open("runtime_config.json").bufferedReader().use { it.readText() })
    private val generationConfig = runtimeConfig.getJSONObject("generation")
    private val retrievalConfig  = runtimeConfig.getJSONObject("retrieval")

    @Volatile private lateinit var engine: Engine

    private val embedder: Embedder<String>
    private val textMemory: DefaultSemanticTextMemory

    init {
        val t0 = System.currentTimeMillis()
        Log.w("mam-ai", "[TIMING] Thread: ${Thread.currentThread().name} — starting heavy init")

        val t1 = System.currentTimeMillis()
        embedder = GeckoEmbeddingModel(
            baseFolder + GECKO_MODEL,
            Optional.of(baseFolder + TOKENIZER_MODEL),
            USE_GPU_FOR_EMBEDDINGS,
        )
        Log.w("mam-ai", "[TIMING] GeckoEmbeddingModel constructor: ${System.currentTimeMillis() - t1}ms")

        val t2 = System.currentTimeMillis()
        textMemory = DefaultSemanticTextMemory(
            SqliteVectorStore(768, baseFolder + "embeddings.sqlite"), embedder
        )
        Log.w("mam-ai", "[TIMING] Remaining init (memory): ${System.currentTimeMillis() - t2}ms")
        Log.w("mam-ai", "[TIMING] Total main-thread init: ${System.currentTimeMillis() - t0}ms")
        val rt = Runtime.getRuntime()
        Log.w("mam-ai", "[MEMORY] heap: ${rt.totalMemory() / 1024 / 1024}MB used, ${rt.freeMemory() / 1024 / 1024}MB free, ${rt.maxMemory() / 1024 / 1024}MB max")
    }

    @Volatile
    var llmReady = false

    // Buffered channel for the LLM being ready - allows coroutine to wait for the llm to be ready
    // Capacity 1 ensures trySend succeeds even if no receiver is waiting yet
    // https://stackoverflow.com/a/55421973
    val onLlmReady = Channel<Unit>(1)

    private val initStartTime = System.currentTimeMillis()

    // Engine.initialize() is a blocking call that loads the model file.
    // Run it on a background thread so we don't block the main thread.
    init {
        Executors.newSingleThreadExecutor().execute {
            try {
                Log.w("mam-ai", "[TIMING] Engine.initialize() starting...")
                engine = Engine(
                    EngineConfig(
                        modelPath = baseFolder + GEMMA_MODEL,
                        backend = Backend.CPU(),
                        cacheDir = application.cacheDir.path,
                    )
                )
                engine.initialize()
                Log.w("mam-ai", "[TIMING] Engine ready: ${System.currentTimeMillis() - initStartTime}ms after construction")
                val rt = Runtime.getRuntime()
                Log.w("mam-ai", "[MEMORY] post-init heap: ${rt.totalMemory() / 1024 / 1024}MB used, ${rt.freeMemory() / 1024 / 1024}MB free, ${rt.maxMemory() / 1024 / 1024}MB max")
                Log.i("mam-ai", "LLM initialized!")
                // UNCOMMENT IF YOU WANT TO ADD MORE CONTEXT
                // memorizeChunks(application.applicationContext, "mamai_trim.txt")
                // Log.i("mam-ai", "Chunks loaded!")

                llmReady = true
                onLlmReady.trySend(Unit)
            } catch (t: Throwable) {
                Log.e("mam-ai", "[ERROR] LLM initialization failed after ${System.currentTimeMillis() - initStartTime}ms", t)
                Log.e("mam-ai", "[ERROR] LLM will not be available. App may crash on query attempts.")
                // Signal anyway to unblock waiting coroutines
                onLlmReady.trySend(Unit)
            }
        }
    }

    // Memorise the given file (from inside the app context)
    // Unused at the moment, since we ship a pre-memorised sqlite DB, but this is the code that
    // could be used to memorise more documents on the fly
    fun memorizeChunks(context: Context, filename: String) {
        // BufferedReader is needed to read the *.txt file
        // Create and Initialize BufferedReader
        val reader = BufferedReader(InputStreamReader(context.assets.open(filename)))

        val sb = StringBuilder()
        val texts = mutableListOf<String>()
        generateSequence { reader.readLine() }
            .forEach { line ->
                for (prefix in CHUNK_SEPARATORS) {
                    if (line.startsWith(prefix)) {
                        if (sb.isNotEmpty()) {
                            val chunk = sb.toString()
                            texts.add(chunk)
                        }
                        sb.clear()
                        sb.append(line.removePrefix(prefix).trim())
                        return@forEach
                    }
                }

                sb.append(" ")
                sb.append(line)
            }
        if (sb.isNotEmpty()) {
            texts.add(sb.toString())
        }
        reader.close()
        if (texts.isEmpty()) {
            Log.i("mam-ai", "Texts is empty!")
        } else {
            Log.i("mam-ai", "Texts is " + texts.size)
            return memorize(texts)
        }
    }

    /** Stores input texts in the semantic text memory. */
    private fun memorize(facts: List<String>) {
        textMemory.recordBatchedMemoryItems(ImmutableList.copyOf(facts)).get()
    }

    /** Parse the [SOURCE:stem|PAGE:n] prefix from a raw chunk string. */
    private fun parseChunkMetadata(raw: String): RetrievedDoc {
        val match = METADATA_PREFIX.find(raw)
        return if (match != null) {
            RetrievedDoc(
                text = raw.substring(match.range.last + 1).trim(),
                source = match.groupValues[1],
                page = match.groupValues[2].toIntOrNull() ?: 0,
            )
        } else {
            RetrievedDoc(text = raw, source = "", page = 0)
        }
    }

    /** Generates the response from the LLM with conversation history support. */
    suspend fun generateResponse(
        prompt: String,
        history: List<Map<String, String>>,
        useRetrieval: Boolean = true,
        language: String = "en",
        retrievalListener: (docs: List<RetrievedDoc>) -> Unit,
        generationListener: (partial: String, done: Boolean) -> Unit,
    ): String =
        coroutineScope {
            // Wait for llm to be ready via rendezvous channel
            if (!llmReady) {
                onLlmReady.receive()
                // Check again after receiving - if still not ready, initialization failed
                if (!llmReady) {
                    throw IllegalStateException("LLM initialization failed. Cannot process queries. Check logcat for details.")
                }
            }

            Log.w("mam-ai", "[QUERY] prompt: \"${prompt.take(80)}...\", history turns: ${history.size}, retrieval: $useRetrieval, language: $language")
            val qStart = System.currentTimeMillis()

            val docs = if (useRetrieval) {
                val retrievalRequest = RetrievalRequest.create(
                    prompt,
                    RetrievalConfig.create(
                    retrievalConfig.getInt("top_k"),
                    retrievalConfig.getDouble("similarity_threshold").toFloat(),
                    TaskType.RETRIEVAL_QUERY
                )
                )
                val rawResults = textMemory.retrieveResults(retrievalRequest).await().getEntities().map { e -> e.data }.toList()
                val parsedDocs = rawResults.map { parseChunkMetadata(it) }
                Log.w("mam-ai", "[TIMING] retrieval (embed + vector search): ${System.currentTimeMillis() - qStart}ms, ${parsedDocs.size} docs")
                retrievalListener(parsedDocs)
                Log.w("mam-ai", "[RETRIEVAL] docs sent to Flutter, starting generation")
                parsedDocs
            } else {
                Log.w("mam-ai", "[RETRIEVAL] skipped by user")
                emptyList()
            }

            // Number the documents so the LLM can cite them as [1], [2], [3].
            val contextStr = docs.mapIndexed { i, doc -> "Document ${i + 1}:\n${doc.text}" }.joinToString("\n\n")

            val systemInstructions = if (language == "sw") systemInstructionsSw else systemInstructionsEn
            val contextLabel = if (language == "sw")
                "MUKTADHA UNAOHUSIANA KUTOKA KWA MIONGOZO YA KIMATIBABU:"
            else
                "RELEVANT CONTEXT FROM MEDICAL GUIDELINES:"
            val questionLabel = if (language == "sw") "Swali:" else "Question:"

            // Build the final user message: retrieved context (if any) followed by the question.
            // LiteRT-LM handles the chat template internally, so we only supply the content.
            val queryMessage = buildString {
                if (contextStr.isNotEmpty()) append("$contextLabel\n$contextStr\n\n")
                append("$questionLabel $prompt")
            }

            // Pass conversation history via initialMessages; system instructions via systemInstruction.
            val conversationConfig = ConversationConfig(
                systemInstruction = Contents.of(systemInstructions),
                initialMessages = history.map { turn ->
                    if (turn["role"] == "user") Message.user(turn["text"] ?: "")
                    else Message.model(turn["text"] ?: "")
                },
                samplerConfig = SamplerConfig(
                    topK = generationConfig.getInt("top_k"),
                    topP = generationConfig.getDouble("top_p"),
                    temperature = generationConfig.getDouble("temperature"),
                ),
            )

            if (BuildConfig.DEBUG) {
                Log.w("mam-ai", "[PROMPT] queryMessage sent to LLM:\n$queryMessage")
            } else {
                Log.w("mam-ai", "[PROMPT] length=${queryMessage.length} history=${history.size} docs=${docs.size}")
            }

            val genStart = System.currentTimeMillis()
            var firstTokenTime = 0L
            val accumulated = StringBuilder()

            // Create a fresh Conversation for each query — history is supplied via initialMessages,
            // so the Conversation does not need to persist across queries.
            engine.createConversation(conversationConfig).use { conversation ->
                conversation.sendMessageAsync(queryMessage)
                    .collect { message ->
                        val token = message.toString()
                        accumulated.append(token)
                        if (firstTokenTime == 0L && token.isNotEmpty()) {
                            firstTokenTime = System.currentTimeMillis()
                            Log.w("mam-ai", "[TIMING] TTFT (time-to-first-token): ${firstTokenTime - genStart}ms")
                        }
                        generationListener(token, false)
                    }
            }
            generationListener("", true)

            val genEnd = System.currentTimeMillis()
            val result = accumulated.toString()
            Log.w("mam-ai", "[TIMING] generation total: ${genEnd - genStart}ms, ${result.length} chars")
            if (firstTokenTime > 0) {
                Log.w("mam-ai", "[TIMING] prefill (to 1st token): ${firstTokenTime - genStart}ms, decode: ${genEnd - firstTokenTime}ms")
            }
            Log.w("mam-ai", "[TIMING] total query: ${System.currentTimeMillis() - qStart}ms")
            result
        }

    companion object {
        private const val USE_GPU_FOR_EMBEDDINGS = false
        private val CHUNK_SEPARATORS = listOf("<sep>", "<doc_sep>")
        // Matches the [SOURCE:stem|PAGE:n] prefix written by chunk_guidelines.py
        private val METADATA_PREFIX = Regex("""^\[SOURCE:([^|]+)\|PAGE:(\d+)\]""")

        private const val GEMMA_MODEL = "gemma-4-E4B-it.litertlm"
        private const val TOKENIZER_MODEL = "sentencepiece.model"
        private const val GECKO_MODEL = "Gecko_1024_quant.tflite"
    }
}
