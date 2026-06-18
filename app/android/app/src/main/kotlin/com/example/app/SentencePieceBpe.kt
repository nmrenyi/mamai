/**
 * Minimal SentencePiece BPE tokenizer for EmbeddingGemma's Gemma tokenizer.
 * Pure-JVM (no Android deps) so it can be unit-validated with kotlinc against the
 * Python `sentencepiece` reference, then dropped into the Android app verbatim.
 *
 * Model facts (verified from sentencepiece.model): model_type=BPE,
 * byte_fallback=true, add_dummy_prefix=false, escape_whitespaces=true
 * (space -> U+2581 '▁'), normalization=identity. Byte tokens "<0xNN>" present.
 */
package com.example.app

import java.io.File

class SentencePieceBpe private constructor(
    private val pieceToId: HashMap<String, Int>,
    private val idScore: FloatArray,
    private val byteTokenId: IntArray,   // 0..255 -> id of "<0xNN>"
    private val userDefined: List<String>,
    val unkId: Int,
) {
    private val space = "▁" // ▁

    /** Encode raw text to token ids (BPE), no special tokens added. */
    fun encodeAsIds(text: String): IntArray {
        // escape_whitespaces: replace ' ' with ▁ (no dummy prefix).
        val norm = text.replace(" ", space)
        // 1) split into symbols (longest user-defined match, else one codepoint)
        val symbols = ArrayList<String>()
        var i = 0
        while (i < norm.length) {
            val ud = matchUserDefined(norm, i)
            if (ud != null) { symbols.add(ud); i += ud.length }
            else { val cp = norm.codePointAt(i); val s = String(Character.toChars(cp)); symbols.add(s); i += s.length }
        }
        if (symbols.isEmpty()) return IntArray(0)

        // 2) BPE merge using a doubly-linked list + priority queue keyed by
        //    (merged-piece score desc, left index asc) — matches SP bpe_model.cc.
        val syms = symbols.toMutableList()
        val prev = IntArray(syms.size) { it - 1 }
        val next = IntArray(syms.size) { if (it == syms.size - 1) -1 else it + 1 }
        val alive = BooleanArray(syms.size) { true }

        data class Pair3(val left: Int, val right: Int, val score: Float, val merged: String)
        val pq = java.util.PriorityQueue<Pair3>(compareByDescending<Pair3> { it.score }.thenBy { it.left })
        fun tryAdd(l: Int, r: Int) {
            if (l < 0 || r < 0) return
            val m = syms[l] + syms[r]
            val id = pieceToId[m] ?: return
            pq.add(Pair3(l, r, idScore[id], m))
        }
        for (k in 0 until syms.size - 1) tryAdd(k, k + 1)

        while (pq.isNotEmpty()) {
            val p = pq.poll()
            if (!alive[p.left] || !alive[p.right]) continue
            if (next[p.left] != p.right) continue
            if (syms[p.left] + syms[p.right] != p.merged) continue
            // merge right into left
            syms[p.left] = p.merged
            alive[p.right] = false
            val nr = next[p.right]
            next[p.left] = nr
            if (nr >= 0) prev[nr] = p.left
            tryAdd(prev[p.left], p.left)
            tryAdd(p.left, next[p.left])
        }

        // 3) emit ids; byte-fallback for symbols not in vocab
        val out = ArrayList<Int>()
        var idx = 0
        // find head
        var head = 0; while (head < alive.size && !alive[head]) head++
        var c = head
        // walk via next[] from the first alive symbol that is index 0's chain head
        // (index 0 is always alive: merges only kill right elements)
        c = 0
        while (c != -1) {
            val s = syms[c]
            val id = pieceToId[s]
            if (id != null) out.add(id)
            else for (b in s.toByteArray(Charsets.UTF_8)) out.add(byteTokenId[b.toInt() and 0xFF])
            c = next[c]
        }
        idx++
        return out.toIntArray()
    }

    private fun matchUserDefined(s: String, pos: Int): String? {
        var best: String? = null
        for (u in userDefined) {
            if (u.length > best?.length ?: 0 && s.regionMatches(pos, u, 0, u.length)) best = u
        }
        return best
    }

    companion object {
        const val BOS = 2
        const val EOS = 1

        fun load(modelPath: String): SentencePieceBpe = loadBytes(File(modelPath).readBytes())

        fun loadBytes(buf: ByteArray): SentencePieceBpe {
            val pieceToId = HashMap<String, Int>(300000)
            val scores = ArrayList<Float>(262144)
            val byteTokenId = IntArray(256) { -1 }
            val userDefined = ArrayList<String>()
            var unkId = 3
            var id = 0
            var p = 0
            // top-level ModelProto: field 1 (pieces) = length-delimited submessages
            while (p < buf.size) {
                val (tag, p1) = readVarint(buf, p); p = p1
                val field = (tag ushr 3).toInt(); val wt = (tag and 7).toInt()
                if (field == 1 && wt == 2) {
                    val (len, p2) = readVarint(buf, p); p = p2
                    val end = p + len.toInt()
                    var piece = ""; var score = 0f; var type = 1
                    var q = p
                    while (q < end) {
                        val (t2, q1) = readVarint(buf, q); q = q1
                        val f2 = (t2 ushr 3).toInt(); val w2 = (t2 and 7).toInt()
                        when {
                            f2 == 1 && w2 == 2 -> { val (l, q2) = readVarint(buf, q); q = q2; piece = String(buf, q, l.toInt(), Charsets.UTF_8); q += l.toInt() }
                            f2 == 2 && w2 == 5 -> { score = java.lang.Float.intBitsToFloat(le32(buf, q)); q += 4 }
                            f2 == 3 && w2 == 0 -> { val (v, q2) = readVarint(buf, q); q = q2; type = v.toInt() }
                            else -> q = skip(buf, q, w2)
                        }
                    }
                    p = end
                    pieceToId[piece] = id
                    scores.add(score)
                    when (type) {
                        2 -> unkId = id
                        4 -> userDefined.add(piece)
                        6 -> { // BYTE piece "<0xNN>"
                            val hex = piece.substring(3, piece.length - 1)
                            byteTokenId[hex.toInt(16)] = id
                        }
                    }
                    id++
                } else {
                    p = skip(buf, p, wt)
                }
            }
            // longest user-defined first for greedy match
            userDefined.sortByDescending { it.length }
            return SentencePieceBpe(pieceToId, scores.toFloatArray(), byteTokenId, userDefined, unkId)
        }

        private fun readVarint(b: ByteArray, start: Int): kotlin.Pair<Long, Int> {
            var p = start; var shift = 0; var result = 0L
            while (true) {
                val x = b[p].toInt() and 0xFF; p++
                result = result or ((x.toLong() and 0x7F) shl shift)
                if (x and 0x80 == 0) break
                shift += 7
            }
            return kotlin.Pair(result, p)
        }
        private fun le32(b: ByteArray, p: Int): Int =
            (b[p].toInt() and 0xFF) or ((b[p+1].toInt() and 0xFF) shl 8) or ((b[p+2].toInt() and 0xFF) shl 16) or ((b[p+3].toInt() and 0xFF) shl 24)
        private fun skip(b: ByteArray, start: Int, wt: Int): Int {
            var p = start
            return when (wt) {
                0 -> readVarint(b, p).second
                1 -> p + 8
                2 -> { val (l, p2) = readVarint(b, p); p2 + l.toInt() }
                5 -> p + 4
                else -> throw IllegalStateException("bad wiretype $wt")
            }
        }
    }
}

