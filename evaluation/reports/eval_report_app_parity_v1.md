# MAM-AI Evaluation Report — Protocol app_parity_v1

**Run date**: 2026-04-11  
**Model**: gemma4-e4b (Gemma 3n E4B int4, GGUF, CPU inference)  
**Protocol**: `app_parity_v1`  
**Prompt version**: `v3-cd8c872e`  
**System prompt SHA-256**: `fc3a0d7a72184985d0ed4d424768fc7e95e2883432979fb2ae2e91eb85717f6d`

---

## What changed vs. previous reports

This is the first evaluation run under the `app_parity_v1` protocol, which represents a significant methodological overhaul:

1. **Unified config**: All runtime parameters (temperature, top_k, top_p, retrieval thresholds, context injection labels) now live in `config/runtime_config.json` — a single source of truth shared by both the Android app and the eval pipeline. Previous runs had separate, potentially drifted values.

2. **App-parity system prompts**: The open-ended system prompt is now loaded directly from `config/prompts/system_en.txt`, the exact same file compiled into the APK via Gradle `srcDirs`. The SHA-256 above uniquely identifies this prompt version. Previous open-ended eval used a generic 2-sentence stub that did not reflect deployed behaviour.

3. **MCQ adapter prompt**: MCQ evaluation uses a separate `config/prompts/mcq_system.txt`. The app's clinical prose prompt is structurally incompatible with single-letter MCQ output (see GitHub issue #39). MCQ scores are therefore a knowledge proxy, not a deployment-fidelity measure.

4. **Versioned RAG contexts**: Retrieved contexts are pre-computed once with a locked version label (`app-parity-v1-topk3-v1`) and reused across all +RAG runs, ensuring reproducibility. The manifest records the exact embedding DB, Gecko model, and tokenizer SHA-256s used.

5. **Parallel cluster execution**: Each dataset ran on a dedicated GPU (separate RunAI job), eliminating GPU contention from the previous single-job design.

**Result directories**:
- No-RAG: `evaluation/results/gemma4-e4b/norag-full-20260411T095630/`
- +RAG: `evaluation/results/gemma4-e4b/rag-full-20260411T100449/`

---

## Generation parameters

| Parameter | Value |
|-----------|-------|
| temperature | 1.0 |
| top_p | 0.95 |
| top_k | 64 |
| n_ctx | 4096 |
| max_tokens | 2048 |

---

## RAG context provenance (+RAG runs)

| Field | Value |
|-------|-------|
| context_version | app-parity-v1-topk3-v1 |
| top_k | 3 |
| repo_commit | faa3bfb77ea7b198e8bc18060209163a225af269 |
| chunk_count | 21,731 |
| source_count | 55 |
| embeddings.sqlite SHA-256 | cf2913df802e2578bd3e91340f607b54464e798… |
| Gecko model SHA-256 | 2334395c8192ea6466093dc39177c52453… |

---

## MCQ Results

MCQ datasets test factual medical knowledge. Score = fraction of questions where the model's response contained the correct answer letter.

| Dataset | n | No-RAG Accuracy | No-RAG Partial | +RAG Accuracy | +RAG Partial | RAG Δ |
|---------|---|----------------|----------------|--------------|--------------|-------|
| afrimedqa_mcq | 660 | 36.97% (244/660) | 41.60% | 33.48% (221/660) | 38.14% | **−3.49 pp** |
| medqa_usmle | 1,025 | 40.78% (418/1025) | 40.78% | 39.22% (402/1025) | 39.22% | **−1.56 pp** |
| medmcqa_mcq | 500 | 51.00% (255/500) | 51.00% | 39.40% (197/500) | 39.40% | **−11.60 pp** |

**Partial credit**: For afrimedqa_mcq, partial credit is ~4.6 pp above strict accuracy (no-RAG), suggesting the model often produces a response near-correct but with imprecise letter formatting. For medqa_usmle and medmcqa_mcq, partial credit equals strict accuracy — responses either clearly hit or miss.

**RAG hurts MCQ**: RAG reduces MCQ accuracy on all three datasets, most severely on medmcqa_mcq (−11.6 pp). Injecting clinical guidelines context appears to distract the model from producing a clean single-letter answer. This is consistent with the MCQ adapter prompt limitation noted in issue #39 — the MCQ prompt was designed for zero-shot letter extraction and does not instruct the model how to use the retrieved context.

**Absolute levels**: medmcqa_mcq at 51.0% (no-RAG) is above the 25% random-chance baseline and approaches passing threshold territory for a 4-option MCQ. afrimedqa_mcq and medqa_usmle are weaker at ~37–41%, suggesting the African-context medical questions are harder for a model trained predominantly on Western medical literature.

---

## Open-ended Results

Open-ended responses were judged by GPT (LLM-as-judge) on five dimensions, each scored 1–5:

| Dimension | Weight | Description |
|-----------|--------|-------------|
| accuracy | 0.30 | Medical correctness of the response |
| safety | 0.25 | Avoidance of harmful advice; appropriate escalation |
| completeness | 0.20 | Coverage of the key clinical points |
| helpfulness | 0.15 | Actionable, practical guidance |
| clarity | 0.10 | Clear, readable language |

### Weighted scores (out of 5)

| Dataset | n | No-RAG | +RAG | RAG Δ |
|---------|---|--------|------|-------|
| kenya_vignettes | 284 | 2.76 | 2.43 | **−0.33** |
| afrimedqa_saq | 37 | 2.57 | 2.17 | **−0.40** |
| whb_stumps | 20 | 2.51 | 2.68 | **+0.17** |

### Per-dimension breakdown — No-RAG

| Dataset | accuracy | safety | completeness | helpfulness | clarity |
|---------|----------|--------|--------------|-------------|---------|
| kenya_vignettes | 2.68 | 3.19 | 1.83 | 2.58 | 4.00 |
| afrimedqa_saq | 2.35 | 3.41 | 1.54 | 2.05 | 3.97 |
| whb_stumps | 2.35 | 3.25 | 1.35 | 2.10 | 4.05 |

### Per-dimension breakdown — +RAG

| Dataset | accuracy | safety | completeness | helpfulness | clarity |
|---------|----------|--------|--------------|-------------|---------|
| kenya_vignettes | 2.33 | 2.93 | 1.48 | 2.07 | 3.96 |
| afrimedqa_saq | 1.73 | 3.24 | 1.14 | 1.43 | 4.00 |
| whb_stumps | 2.70 | 3.15 | 1.65 | 2.30 | 4.05 |

### Score distributions (No-RAG)

**kenya_vignettes** (n=284):

| Score | accuracy | safety | completeness | helpfulness | clarity |
|-------|----------|--------|--------------|-------------|---------|
| 1 | 7 | 2 | 65 | 16 | 0 |
| 2 | 99 | 31 | 201 | 102 | 0 |
| 3 | 155 | 162 | 18 | 152 | 4 |
| 4 | 23 | 88 | 0 | 14 | 277 |
| 5 | 0 | 1 | 0 | 0 | 3 |

**afrimedqa_saq** (n=37):

| Score | accuracy | safety | completeness | helpfulness | clarity |
|-------|----------|--------|--------------|-------------|---------|
| 1 | 11 | 0 | 19 | 15 | 0 |
| 2 | 6 | 0 | 16 | 6 | 0 |
| 3 | 16 | 23 | 2 | 15 | 1 |
| 4 | 4 | 13 | 0 | 1 | 36 |
| 5 | 0 | 1 | 0 | 0 | 0 |

**whb_stumps** (n=20):

| Score | accuracy | safety | completeness | helpfulness | clarity |
|-------|----------|--------|--------------|-------------|---------|
| 1 | 5 | 0 | 13 | 4 | 0 |
| 2 | 5 | 3 | 7 | 10 | 0 |
| 3 | 8 | 9 | 0 | 6 | 0 |
| 4 | 2 | 8 | 0 | 0 | 19 |
| 5 | 0 | 0 | 0 | 0 | 1 |

---

## Key findings

### 1. RAG hurts more than it helps under the current protocol

RAG degrades performance across nearly all datasets and dimensions:
- MCQ: −1.6 to −11.6 pp accuracy
- Open-ended weighted score: −0.33 to −0.40 on kenya_vignettes and afrimedqa_saq
- The single exception is whb_stumps (+0.17), where RAG marginally helps

The most likely cause is a **prompt construction mismatch**: the MCQ adapter prompt does not instruct the model how to reason over the retrieved context, and the app system prompt (used for open-ended) may be instructing the model to cite documents as `[1]`, `[2]`, `[3]` while the eval's GGUF model may not handle this gracefully. This warrants investigation — specifically, whether the GGUF inference path reproduces the on-device citation behaviour.

### 2. Completeness is the primary quality bottleneck

Completeness scores are the weakest dimension across all three open-ended datasets (1.35–1.83 no-RAG, 1.14–1.65 +RAG). Distribution data shows completeness is overwhelmingly rated 1–2 out of 5. The app system prompt explicitly values conciseness and brevity, which trades off against completeness. This is a deliberate design choice for the intended context (nurses with limited time), but the judge penalises it. This score should be interpreted cautiously — low completeness may reflect appropriate triage-style responses rather than factual gaps.

### 3. Clarity is a consistent strength

Clarity scores cluster tightly at 4.0–4.05 across all conditions. The vast majority of responses receive a 4/5 on clarity. The model writes in clear, readable English, which is a meaningful property for a second-language medical audience.

### 4. Safety is mediocre and slightly hurt by RAG

No-RAG safety: 3.19–3.41. +RAG safety: 2.93–3.24. Safety is never below 3 in the no-RAG condition on average, but kenya_vignettes drops to 2.93 with RAG. The safety score distribution shows occasional 1s and 2s (e.g., 11 safety=1 responses in kenya_vignettes +RAG). Given that this is a medical app for nurses and midwives, any systematic safety degradation from RAG is a concern. These cases should be manually reviewed before any production deployment with RAG enabled.

### 5. MCQ levels in context

| Dataset | Score | Baseline |
|---------|-------|----------|
| medmcqa_mcq no-RAG | 51.0% | 25% random; ~60% reported for strong 7B models |
| medqa_usmle no-RAG | 40.8% | 25% random; USMLE passing ~60% |
| afrimedqa_mcq no-RAG | 37.0% | 25% random; African-context harder |

The model performs significantly above chance but well below state-of-the-art medical LLMs. This is expected for an on-device 4-bit quantised E4B model running on CPU. The relevant question is whether the scores are sufficient for the intended assistive (not diagnostic) use case.

---

## Judge metadata

- All 321 (no-RAG) and 321 (+RAG) open-ended responses were judged with 0 judge failures
- Judge model: configured via `config/eval_config.json` (`judge_model` field)
- Dimension weights: accuracy 0.30 · safety 0.25 · completeness 0.20 · helpfulness 0.15 · clarity 0.10

---

## Recommendations

1. **Investigate RAG regression**: Before enabling RAG in the app, understand why MCQ drops sharply with context injection. Inspect individual +RAG responses on medmcqa_mcq to determine whether the model is ignoring, misusing, or confused by the injected guidelines.

2. **Manual review of low-safety +RAG responses**: The 11 kenya_vignettes responses rated safety=1 with RAG should be reviewed. If they represent cases where injected context displaced appropriate escalation language, this is a deployment risk.

3. **Reframe completeness interpretation**: Consider whether the judge's completeness rubric is calibrated for concise clinical triage responses or for comprehensive clinical notes. The app prompt is designed for the former; if the judge expects the latter, completeness scores are systematically pessimistic.

4. **Caution on small-n datasets**: whb_stumps (n=20) and afrimedqa_saq (n=37) have high variance. The +RAG whb_stumps improvement of +0.17 is not meaningful at n=20. These should be treated as indicative only.

5. **Next run: ablate context injection format**: Test whether reformatting the RAG context injection (e.g., removing the `Document N:` prefix, using bullet points) improves MCQ and open-ended scores under RAG.
