# MAM-AI TODO

## Immediate (unblocked)

- [ ] **Evaluate Gemma 4 E4B quality** — Run the same 6-benchmark suite from `evaluation/EVAL_REPORT.md` against the currently deployed Gemma 4 E4B model. Compare MCQ accuracy and open-ended scores against the Gemma 3n E4B baseline. Update `EVAL_REPORT.md` with results.

- [ ] **Test GPU backend with E2B** — Switch `feat/gpu-backend` branch to use `gemma-4-E2B-it.litertlm` instead of E4B (community reports E2B works on GPU while E4B crashes). Measure TTFT and decode speed on device. If GPU TTFT is significantly lower, E2B on GPU may outperform E4B on CPU overall — and it is 1 GB smaller.

- [ ] **Fix RAG pipeline retrieval** — `EVAL_REPORT.md` shows RAG hurts MCQ accuracy for all on-device models (-2 to -6 pp). Current similarity threshold is 0.0 (no filtering) in `app/android/app/src/main/kotlin/com/example/app/RagPipeline.kt:183`. Options: raise the threshold, reduce retrieved chunks from 3 to fewer, or only inject context above a confidence cutoff.

## Near-term

- [ ] **Complete GPT-5 Kenya Vignettes evaluation** — Only 31/284 questions evaluated before API quota ran out. Top up credits and resume using `--run-dir` auto-resume.

- [ ] **Finalize and commit README** — README has uncommitted edits replacing evaluation results with "coming soon" placeholders. Once Gemma 4 E4B evaluation results are ready, update with real numbers and commit.

## Blocked

- [ ] **GPU backend with E4B** — Waiting for LiteRT-LM 0.10.1 on Google Maven. The 0.10.0 Android AAR crashes on GPU decode (`Failed to clEnqueueNDRangeKernel`). Track: [google-ai-edge/LiteRT-LM#1850](https://github.com/google-ai-edge/LiteRT-LM/issues/1850).
