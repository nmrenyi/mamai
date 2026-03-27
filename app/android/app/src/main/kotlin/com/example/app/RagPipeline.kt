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
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.guava.await
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.Optional
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
    private val mediaPipeLanguageModelOptions: LlmInferenceOptions =
        LlmInferenceOptions.builder()
            .setModelPath(baseFolder + GEMMA_MODEL)
            .setPreferredBackend(LlmInference.Backend.CPU)
            .setMaxTokens(32000)  // Gemma 3n E4B IT has 32k context window
            .build()
    private val mediaPipeLanguageModelSessionOptions: LlmInferenceSession.LlmInferenceSessionOptions =
        LlmInferenceSession.LlmInferenceSessionOptions.builder()
            .setTemperature(1.0f)
            .setTopP(0.95f)
            .setTopK(64)
            .build()

    // Owned directly so we can create/cancel sessions and call cancelGenerateResponseAsync()
    @Volatile private lateinit var llmInference: LlmInference
    @Volatile private var currentSession: LlmInferenceSession? = null

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

    // LlmInference.createFromOptions() is a blocking call that loads the model file.
    // Run it on a background thread so we don't block the main thread.
    init {
        Executors.newSingleThreadExecutor().execute {
            try {
                Log.w("mam-ai", "[TIMING] LlmInference.createFromOptions starting...")
                llmInference = LlmInference.createFromOptions(
                    application.applicationContext,
                    mediaPipeLanguageModelOptions
                )
                Log.w("mam-ai", "[TIMING] LlmInference ready: ${System.currentTimeMillis() - initStartTime}ms after construction")
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

    /** Abort the currently running session's native inference. */
    fun cancelGeneration() {
        currentSession?.cancelGenerateResponseAsync()
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
                    RetrievalConfig.create(3, 0.0f, TaskType.RETRIEVAL_QUERY)
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

            // Construct the full prompt using Gemma IT chat template.
            // Number the documents so the LLM can cite them as [1], [2], [3].
            val contextStr = docs.mapIndexed { i, doc -> "Document ${i + 1}:\n${doc.text}" }.joinToString("\n\n")
            val fullPrompt = buildPrompt(contextStr, history, prompt, language)

            if (BuildConfig.DEBUG) {
                Log.w("mam-ai", "[PROMPT] full prompt sent to LLM:\n$fullPrompt")
            } else {
                Log.w("mam-ai", "[PROMPT] length=${fullPrompt.length} history=${history.size} docs=${docs.size}")
            }

            val genStart = System.currentTimeMillis()
            var firstTokenTime = 0L

            // Create a fresh session for each query. We build the full Gemma IT prompt ourselves
            // (including all history), so the session must not accumulate its own context.
            val session = LlmInferenceSession.createFromOptions(
                llmInference,
                mediaPipeLanguageModelSessionOptions
            )

            try {
                // Expose the session before addQueryChunk so that a cancelGeneration()
                // call arriving on the main thread during addQueryChunk or generateResponseAsync
                // can still reach cancelGenerateResponseAsync() and abort the native inference.
                currentSession = session
                session.addQueryChunk(fullPrompt)
                val result = session.generateResponseAsync { partial, done ->
                    if (firstTokenTime == 0L && partial.isNotEmpty()) {
                        firstTokenTime = System.currentTimeMillis()
                        Log.w("mam-ai", "[TIMING] TTFT (time-to-first-token): ${firstTokenTime - genStart}ms")
                    }
                    generationListener(partial, done)
                }.await()
                val genEnd = System.currentTimeMillis()
                Log.w("mam-ai", "[TIMING] generation total: ${genEnd - genStart}ms, ${result.length} chars")
                if (firstTokenTime > 0) {
                    Log.w("mam-ai", "[TIMING] prefill (to 1st token): ${firstTokenTime - genStart}ms, decode: ${genEnd - firstTokenTime}ms")
                }
                Log.w("mam-ai", "[TIMING] total query: ${System.currentTimeMillis() - qStart}ms")
                result
            } finally {
                // Null out before close so cancelGeneration() on the main thread cannot
                // call cancelGenerateResponseAsync() on an already-closed session
                currentSession = null
                session.close()
            }
        }

    /**
     * Builds a prompt using the Gemma IT chat template.
     * Format: <start_of_turn>user / <end_of_turn> / <start_of_turn>model
     * System instructions go in the first user turn. Retrieved context is placed
     * immediately before the query it was retrieved for (the current/final user turn).
     */
    private fun buildPrompt(
        context: String,
        history: List<Map<String, String>>,
        query: String,
        language: String = "en",
    ): String {
        val systemInstructions = if (language == "sw") SYSTEM_INSTRUCTIONS_SW else SYSTEM_INSTRUCTIONS
        // Context/query labels are also localised so the model understands the prompt structure
        val contextLabel = if (language == "sw")
            "MUKTADHA UNAOHUSIANA KUTOKA KWA MIONGOZO YA KIMATIBABU:"
        else
            "RELEVANT CONTEXT FROM MEDICAL GUIDELINES:"
        val questionLabel = if (language == "sw") "Swali:" else "Question:"

        val sb = StringBuilder()

        // First user turn — system instructions only
        sb.append("<start_of_turn>user\n")
        sb.append(systemInstructions)

        if (history.isEmpty()) {
            // No history: context + current query go in the first (and only) user turn
            if (context.isNotEmpty()) {
                sb.append("\n$contextLabel\n$context\n")
            }
            sb.append("\n$questionLabel $query<end_of_turn>\n")
        } else {
            // History: first historical user message closes the first turn (system instructions only)
            sb.append("\n$questionLabel ${history.first()["text"]}<end_of_turn>\n")
            // Remaining history turns alternate model/user
            for (turn in history.drop(1)) {
                if (turn["role"] == "user") {
                    sb.append("<start_of_turn>user\n$questionLabel ${turn["text"]}<end_of_turn>\n")
                } else {
                    sb.append("<start_of_turn>model\n${turn["text"]}<end_of_turn>\n")
                }
            }
            // Current query as the final user turn, with retrieved context immediately before it
            sb.append("<start_of_turn>user\n")
            if (context.isNotEmpty()) {
                sb.append("$contextLabel\n$context\n\n")
            }
            sb.append("$questionLabel $query<end_of_turn>\n")
        }

        // Trigger generation — no closing <end_of_turn>
        sb.append("<start_of_turn>model\n")
        return sb.toString()
    }

    companion object {
        private const val USE_GPU_FOR_EMBEDDINGS = false
        private val CHUNK_SEPARATORS = listOf("<sep>", "<doc_sep>")
        // Matches the [SOURCE:stem|PAGE:n] prefix written by chunk_guidelines.py
        private val METADATA_PREFIX = Regex("""^\[SOURCE:([^|]+)\|PAGE:(\d+)\]""")

        private const val GEMMA_MODEL = "gemma-3n-E4B-it-int4.task"
        private const val TOKENIZER_MODEL = "sentencepiece.model"
        private const val GECKO_MODEL = "Gecko_1024_quant.tflite"

        private const val SYSTEM_INSTRUCTIONS =
            "You are a clinical decision-support assistant for nurse-midwives in Zanzibar. Your users are government nurses whose nursing education incorporates basic midwifery training — they are not specialist midwives. They work at primary, secondary, and tertiary government health facilities, often with limited resources and specialist backup.\n" +
            "You help with neonatal care, maternal health, obstetrics, and related clinical topics.\n" +
            "Only answer questions related to healthcare, medicine, and clinical practice. For unrelated topics, politely decline and redirect to clinical questions.\n" +
            "\n" +
            "CONVERSATION: You may have access to previous messages in this conversation — use them to maintain context and avoid repeating information already covered.\n" +
            "\n" +
            "LANGUAGE & TONE: Use simple, short sentences. Avoid idioms and complex words. Answer in English. Be supportive, professional, and calm.\n" +
            "\n" +
            "FORMAT: Use markdown. Use bullet points for lists. Use **bold** for important terms. Use numbered steps for procedures. Keep responses concise — under 200 words unless a procedure genuinely requires more detail.\n" +
            "\n" +
            "USING CONTEXT: If retrieved context is provided, use it to answer. If the context is not relevant to the question, say so and answer from established medical knowledge instead. When you use information from a document, add its citation number at the end of the relevant sentence — e.g. [1], [2], or [3].\n" +
            "\n" +
            "EMERGENCIES — if any of these are present, immediately advise the nurse to escalate to a doctor or arrange urgent referral, and state why:\n" +
            "- Heavy bleeding (postpartum haemorrhage, antepartum haemorrhage)\n" +
            "- Convulsions or loss of consciousness (eclampsia)\n" +
            "- Cord prolapse or abnormal fetal presentation\n" +
            "- Shoulder dystocia\n" +
            "- Severe difficulty breathing (mother or newborn)\n" +
            "- Fever in a newborn or signs of neonatal sepsis\n" +
            "- Signs of maternal sepsis (fever, rapid pulse, confusion in the mother)\n" +
            "- Severe abdominal pain\n" +
            "\n" +
            "MEDICATIONS: Do not recommend specific drug doses unless the retrieved context explicitly states them. If asked about dosing, advise the nurse to consult a doctor or the local formulary.\n" +
            "\n" +
            "UNCERTAINTY: If you are not sure, admit it clearly (e.g., \u201cI\u2019m not sure. Please consult a doctor or senior clinician.\u201d). Do not guess. Prioritize patient safety above all else."

        // NOTE: Placeholder Swahili translation — pending review by a qualified
        // Swahili-speaking medical professional. See GitHub issue for tracking.
        private const val SYSTEM_INSTRUCTIONS_SW =
            "Wewe ni msaidizi wa maamuzi ya kimatibabu kwa wauguzi-wakunga Zanzibar. Watumiaji wako ni wauguzi wa serikali ambao elimu yao ya uuguzi inajumuisha mafunzo ya msingi ya ukunga \u2014 si wauguzi wakunga wataalamu. Wanafanya kazi katika vituo vya afya vya serikali vya msingi, vya kati na vya juu, mara nyingi na rasilimali chache na msaada mdogo wa wataalamu.\n" +
            "Unasaidia katika utunzaji wa watoto wachanga, afya ya uzazi, uzazishaji, na mada zinazohusiana za kimatibabu.\n" +
            "Jibu maswali yanayohusiana na huduma za afya, dawa, na mazoea ya kimatibabu pekee. Kwa mada zisizohusiana, kataa kwa upole na elekeza maswali ya kimatibabu.\n" +
            "\n" +
            "MAZUNGUMZO: Unaweza kuwa na ufikiaji wa ujumbe wa awali katika mazungumzo haya \u2014 tumia ili kudumisha muktadha na kuepuka kurudia maelezo yaliyoshughulikiwa tayari.\n" +
            "\n" +
            "LUGHA NA SAUTI: Tumia sentensi fupi na rahisi. Epuka misemo na maneno magumu. Jibu kwa Kiswahili. Kuwa na msaada, mtaalamu, na utulivu.\n" +
            "\n" +
            "MUUNDO: Tumia markdown. Tumia vitone vya mpangilio kwa orodha. Tumia **maneno muhimu** kwa maneno ya msingi. Tumia hatua za nambari kwa taratibu. Weka majibu mafupi \u2014 chini ya maneno 200 isipokuwa taratibu inahitaji maelezo zaidi.\n" +
            "\n" +
            "KUTUMIA MUKTADHA: Ikiwa muktadha uliorejeshwa unapatikana, uitumie kujibu. Ikiwa muktadha hauhusiani na swali, sema hivyo na ujibu kutoka kwa maarifa ya kimatibabu yaliyoanzishwa.\n" +
            "\n" +
            "DHARURA \u2014 ikiwa yoyote kati ya hizi yapo, mara moja ushauri muuguzi kuwasiliana na daktari au kupanga rufaa ya haraka, na eleza sababu:\n" +
            "- Kutoka damu nyingi (kutoka damu baada ya kujifungua, kutoka damu kabla ya kujifungua)\n" +
            "- Degedege au kupoteza fahamu (eclampsia)\n" +
            "- Kuteleza kwa kitovu au msimamo usio wa kawaida wa fetasi\n" +
            "- Dystocia ya bega\n" +
            "- Ugumu mkubwa wa kupumua (mama au mtoto mchanga)\n" +
            "- Homa kwa mtoto mchanga au dalili za sepsis ya watoto wachanga\n" +
            "- Dalili za sepsis ya mama (homa, mapigo ya moyo ya haraka, kuchanganyikiwa kwa mama)\n" +
            "- Maumivu makali ya tumbo\n" +
            "\n" +
            "DAWA: Usipendekezee dozi maalum za dawa isipokuwa muktadha uliorejeshwa unaziainisha wazi. Ikiwa unaulizwa kuhusu dozi, ushauri muuguzi kushauriana na daktari au formulari ya eneo.\n" +
            "\n" +
            "KUTOKUWA NA UHAKIKA: Ikiwa huna uhakika, kiri waziwazi (k.m., \u201cSina uhakika. Tafadhali wasiliana na daktari au mkuu wa kliniki.\u201d). Usikisi. Toa kipaumbele usalama wa mgonjwa zaidi ya yote."
    }
}
