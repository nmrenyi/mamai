package com.example.app

import com.google.ai.edge.localagents.rag.models.EmbedData
import com.google.ai.edge.localagents.rag.models.Embedder
import com.google.ai.edge.localagents.rag.models.EmbeddingRequest
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import org.tensorflow.lite.Interpreter
import java.io.File
import kotlin.math.sqrt

/**
 * On-device EmbeddingGemma-300M retriever embedder, implementing the localagents
 * RAG [Embedder] contract so it is a drop-in replacement for [com.google.ai.edge.localagents.rag.models.GeckoEmbeddingModel].
 *
 * Runs the `embeddinggemma-300M_seq256_mixed-precision.tflite` int4/int8 export via
 * the TFLite/LiteRT [Interpreter] (CPU/XNNPACK — the GPU delegate fails op support
 * for this model). Tokenisation uses [SentencePieceBpe] with the Gemma SentencePiece
 * model and EmbeddingGemma's task prompts.
 *
 * Encoding (validated byte-for-byte against the PyTorch `sentence-transformers`
 * reference): `[BOS] + spm(prompt + text) + [EOS]`, truncate/right-pad to 256
 * int32 token ids; output is the 768-dim pooled embedding, L2-normalised. Query vs
 * document prompt is selected from the [EmbedData.TaskType]; the app only embeds
 * queries on-device (documents are pre-embedded in the shipped vector store).
 *
 * The TFLite interpreter is not thread-safe; all inference is serialised on [lock].
 * Queries are already single-flighted upstream (RagStream), so this is uncontended.
 */
class EmbeddingGemmaEmbedder(
    modelPath: String,
    tokenizerPath: String,
    private val seqLen: Int = 256,
    numThreads: Int = 4,
) : Embedder<String> {

    private val tokenizer = SentencePieceBpe.load(tokenizerPath)
    private val interpreter: Interpreter =
        Interpreter(File(modelPath), Interpreter.Options().apply { setNumThreads(numThreads) })
    private val lock = Any()

    private fun promptFor(task: EmbedData.TaskType?): String =
        if (task == EmbedData.TaskType.RETRIEVAL_DOCUMENT) DOC_PROMPT else QUERY_PROMPT

    private fun embedOne(text: String, task: EmbedData.TaskType?): ImmutableList<Float> {
        // [BOS] + spm(prompt + text) + [EOS], truncate/pad to seqLen.
        val pieces = tokenizer.encodeAsIds(promptFor(task) + text)
        val input = Array(1) { IntArray(seqLen) }
        var n = 0
        if (n < seqLen) input[0][n++] = SentencePieceBpe.BOS
        var i = 0
        while (i < pieces.size && n < seqLen - 1) { input[0][n++] = pieces[i]; i++ }
        if (n < seqLen) input[0][n++] = SentencePieceBpe.EOS
        // remaining entries stay 0 (pad id)

        val output = Array(1) { FloatArray(EMBED_DIM) }
        synchronized(lock) { interpreter.run(input, output) }

        val v = output[0]
        var norm = 0f
        for (x in v) norm += x * x
        norm = sqrt(norm) + 1e-9f
        val b = ImmutableList.builder<Float>()
        for (x in v) b.add(x / norm)
        return b.build()
    }

    override fun getEmbeddings(
        request: EmbeddingRequest<String>
    ): ListenableFuture<ImmutableList<Float>> {
        val d = request.embedData[0]
        return Futures.immediateFuture(embedOne(d.data, d.task))
    }

    override fun getBatchEmbeddings(
        request: EmbeddingRequest<String>
    ): ListenableFuture<ImmutableList<ImmutableList<Float>>> {
        val b = ImmutableList.builder<ImmutableList<Float>>()
        for (d in request.embedData) b.add(embedOne(d.data, d.task))
        return Futures.immediateFuture(b.build())
    }

    companion object {
        private const val EMBED_DIM = 768
        // EmbeddingGemma's built-in task prompts (exact; must match the prompts
        // used to embed the corpus in the producer pipeline).
        private const val QUERY_PROMPT = "task: search result | query: "
        private const val DOC_PROMPT = "title: none | text: "
    }
}
