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

            // Number the documents so the LLM can cite them as [1], [2], [3].
            val contextStr = docs.mapIndexed { i, doc -> "Document ${i + 1}:\n${doc.text}" }.joinToString("\n\n")

            val systemInstructions = if (language == "sw") SYSTEM_INSTRUCTIONS_SW else SYSTEM_INSTRUCTIONS
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
                samplerConfig = SamplerConfig(topK = 64, topP = 0.95, temperature = 1.0),
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
