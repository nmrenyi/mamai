# EmbeddingGemma retriever swap — autonomous progress log

Branch: `feat/embeddinggemma-retriever-20260618`. Working autonomously (user away).
Goal: replace the Gecko retriever with EmbeddingGemma-300M on-device, per
`docs/embeddinggemma-gemma3n-upgrade-20260618.md` §1. **Do NOT auto-merge** —
prepare a PR for review (retrieval change on a safety-critical medical app).

## Exact spec (verified from mamai-eval + producer repo + SDK)

- **Model artifact**: `litert-community/embeddinggemma-300m` →
  `embeddinggemma-300M_seq256_mixed-precision.tflite` (generic CPU, mixed int4/int8,
  ~171 MB). Tokenizer `sentencepiece.model` is in the SAME repo. Repo gating: `auto`.
- **Prompts** (exact, must match both sides): query = `task: search result | query: {q}`,
  document = `title: none | text: {chunk}`.
- **Encode**: SentencePiece (Gemma) tokenize the prompted text → int32 token IDs,
  truncate/right-pad to seq **256**, feed `[1,256]`; output 768-dim; **L2-normalize**.
  CPU/XNNPACK only (GPU delegate fails: CAST/EMBEDDING_LOOKUP/GREATER_EQUAL).
- **Vector store**: table `rag_vector_store(ROWID, text, embeddings)`; blob =
  `b"VF32" + struct.pack("<768f", ...)` = 3076 bytes. Reuse producer's `pack_embedding`,
  schema, and `package_bundle.py --version v0.3.0` (edit manifest `embedding.model`).
- **Parity gate**: validate LiteRT int8 output vs PyTorch `sentence_transformers`
  `encode_document/encode_query` (`allclose`, atol≈1e-5) on sample chunks BEFORE
  embedding the full corpus — known silent-garbage int-export bug.
- **Target**: kenya P@3 lenient **0.3964** (Gecko baseline 0.2703).

## Architecture decision
Embed the **corpus with the on-device int8 LiteRT model** (document prompt) so stored
vectors live in the same quantized space as the on-device **query** encoder (query
prompt). The app only embeds queries on-device; documents are pre-embedded in the bundle.

## Plan / status
- [x] 1. Acquire artifacts. Hosted ungated at `nmrenyi/embeddinggemma-300m-litert-mamai`
      (tflite sha `37115ef7…`, sentencepiece sha `d6daa52d…`).
- [x] 2. Python LiteRT embedder + parity. **Validated**: I/O = int32[1,256]→float[1,768];
      tokenization `[bos]+spm(prompt+text)+[eos]` reproduces sentence-transformers EXACTLY;
      LiteRT int8 vs PyTorch FP32 cosine ~0.972 (faithful, not the garbage-export bug);
      retrieval discriminates correctly (PPH query ranks PPH docs 0.64/0.59 vs 0.25/0.23).
- [~] 3. Re-embed corpus (63,650 texts from the v0.2.0 store, doc prompt). RUNNING
      (`/tmp/eg_embed_corpus.py` → `/tmp/eg_embeddings.sqlite`, ~17/s, ~55 min).
- [ ] 4. Producer: build bundle v0.3.0 + host on nmrenyi/mamai-medical-guidelines releases.
- [x] 5a. App Kotlin: `SentencePieceBpe.kt` (BPE, byte-fallback) — **JVM-validated 1007/1007**
      vs Python incl. 1000 real corpus docs + multilingual/emoji/math edge cases.
- [x] 5b. App Kotlin: `EmbeddingGemmaEmbedder.kt` (Embedder<String>, TFLite Interpreter,
      L2-norm, prompts). Wired into RagPipeline behind `app_config.embedder`.
- [x] 5c. App config/plumbing: app_config.json (embedder=embeddinggemma), intro_page
      download URLs + pinned SHA-256 + file list/labels, build.gradle litert dep.
- [ ] 5d. rag_assets.lock.json → v0.3.0 (after bundle hosted).
- [ ] 6. On-device retrieval test + parity spot-check (NEEDS DEVICE).
- [ ] 7. PR for review (not auto-merge).

## Validation evidence (offline, high-confidence)
- Tokenizer parity: `SentencePieceBpe.kt` == Python `sentencepiece` on 1007 inputs (exact).
- Export faithfulness: int8 LiteRT vs FP32 PyTorch mean cos 0.972; correct retrieval ranking.
- I/O contract: input `embed_256_text_batch:0` int32[1,256]; output `StatefulPartitionedCall:0`
  float32[1,768]; tokenizer vocab 262144, bos=2/eos=1/pad=0.

## Remaining device-only risks (call out in PR)
- TFLite `org.tensorflow.lite.Interpreter` running the EG .tflite on the actual device
  (CPU/XNNPACK) — standard, but unverified on hardware.
- End-to-end on-device retrieval quality vs Gecko (spot-check; plan says don't gate on
  answer quality on the Gemma generator).
- Embedder init/latency on a real low-mid device (~0.4–0.75 s/query projected).

## SDK contract (decompiled)
`Embedder<T>`: `ListenableFuture<ImmutableList<Float>> getEmbeddings(EmbeddingRequest<T>)`
and `getBatchEmbeddings(...)`. `EmbedData<T>`: `getData()` (String), `getTask()`
(TaskType RETRIEVAL_QUERY/RETRIEVAL_DOCUMENT), `getMetadata()`. App passes only
RETRIEVAL_QUERY → apply the query prompt.

## Notes / blockers
(append as work proceeds)
