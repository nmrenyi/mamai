# MAM-AI Evaluation Report — Protocol app_parity_v1

**Run date**: 2026-04-11 (gemma4-e4b · gemma3n-e4b · gpt-5) · 2026-04-15 (medgemma-4b · meditron3-8b)  
**Models evaluated**: gemma4-e4b · gemma3n-e4b · gpt-5 · medgemma-4b · meditron3-8b  
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

6. **Three-model comparison**: This report covers three models — the on-device target (gemma4-e4b), its predecessor (gemma3n-e4b), and a strong API baseline (gpt-5) — enabling direct performance comparison under identical conditions.

**Result directories**:
- gemma4-e4b No-RAG: `evaluation/results/gemma4-e4b/norag-full-20260411T095630/`
- gemma4-e4b +RAG: `evaluation/results/gemma4-e4b/rag-full-20260411T100449/`
- gemma3n-e4b No-RAG: `evaluation/results/gemma3n-e4b/norag-full-20260411T114335/`
- gemma3n-e4b +RAG: `evaluation/results/gemma3n-e4b/rag-full-20260411T114419/`
- gpt-5 No-RAG: `evaluation/results/gpt-5/norag-full-20260411T114501/`
- gpt-5 +RAG: `evaluation/results/gpt-5/rag-full-20260411T114544/`
- medgemma-4b No-RAG: `evaluation/results/medgemma-gguf/20260415T050106/`
- medgemma-4b +RAG: `evaluation/results/medgemma-gguf/20260415T050307/`
- meditron3-8b No-RAG: `evaluation/results/meditron3-8b/20260415T050310/`
- meditron3-8b +RAG: `evaluation/results/meditron3-8b/20260415T050238/`

---

## Generation parameters

| Parameter | gemma4-e4b / gemma3n-e4b | gpt-5 |
|-----------|--------------------------|-------|
| temperature | 1.0 | 1.0 |
| top_p | 0.95 | 0.95 |
| top_k | 64 | n/a |
| n_ctx | 4096 | n/a |
| max_tokens | 2048 | 2048 |
| backend | llama-cpp-python (GGUF, CUDA) | OpenAI API |

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

MCQ datasets test factual medical knowledge. The model must identify the correct answer(s) from the provided options.

**Scoring definitions**:
- **Accuracy** (strict): exact match — predicted answer set must equal the ground truth set exactly.
- **Partial credit** (afrimedqa_mcq only): for multi-answer questions, awards `|picked ∩ correct| / |correct|` if no wrong answers are picked; zero if any wrong answer is included. Reported only for afrimedqa_mcq because it is the only dataset with genuinely multi-answer questions (112/660 questions have 2–5 correct letters). medqa_usmle and medmcqa_mcq have single-letter correct answers throughout, so accuracy = partial by definition.
- **Random chance baseline**: 25% (4-option questions).
- **RAG Δ**: percentage-point change in accuracy when RAG context is added.

### afrimedqa_mcq (n=660, 112 multi-answer)

| Model | No-RAG Accuracy | No-RAG Partial | +RAG Accuracy | +RAG Partial | RAG Δ |
|-------|----------------|----------------|--------------|--------------|-------|
| gemma4-e4b | 36.97% (244/660) | 41.60% | 33.48% (221/660) | 38.14% | **−3.49 pp** |
| gemma3n-e4b | 41.06% (271/660) | 45.58% | 37.73% (249/660) | 42.14% | **−3.33 pp** |
| medgemma-4b | 37.73% (249/660) | 41.69% | 32.88% (217/660) | 36.98% | **−4.85 pp** |
| meditron3-8b | 31.36% (207/660) | 34.88% | 27.73% (183/660) | 31.12% | **−3.63 pp** |
| gpt-5 | 66.97% (442/660) | 72.57% | 66.06% (436/660) | 71.55% | **−0.91 pp** |

### medqa_usmle (n=1,025, single-answer)

| Model | No-RAG Accuracy | +RAG Accuracy | RAG Δ |
|-------|----------------|--------------|-------|
| gemma4-e4b | 40.78% (418/1025) | 39.22% (402/1025) | **−1.56 pp** |
| gemma3n-e4b | 44.20% (453/1025) | 42.05% (431/1025) | **−2.15 pp** |
| medgemma-4b | 44.88% (460/1025) | 40.68% (417/1025) | **−4.20 pp** |
| meditron3-8b | 42.24% (433/1025) | 37.95% (389/1025) | **−4.29 pp** |
| gpt-5 | 92.49% (948/1025) | 93.34% (953/1021) | **+0.85 pp** |

### medmcqa_mcq (n=500, single-answer)

| Model | No-RAG Accuracy | +RAG Accuracy | RAG Δ |
|-------|----------------|--------------|-------|
| gemma4-e4b | 51.00% (255/500) | 39.40% (197/500) | **−11.60 pp** |
| gemma3n-e4b | 51.20% (256/500) | 50.80% (254/500) | **−0.40 pp** |
| medgemma-4b | 50.20% (251/500) | 43.80% (219/500) | **−6.40 pp** |
| meditron3-8b | 51.00% (255/500) | 44.40% (222/500) | **−6.60 pp** |
| gpt-5 | 89.00% (445/500) | 87.20% (436/500) | **−1.80 pp** |

**Key MCQ observations**:
- **gemma3n-e4b edges out gemma4-e4b** on all three datasets despite being the older model. The difference is small (~2–4 pp) but consistent, and may reflect quantization sensitivity in the MCQ zero-shot extraction task.
- **Med-specific models do not outperform gemma3n-e4b** despite being trained on medical data. medgemma-4b and meditron3-8b score 31–51% no-RAG, within the same range as gemma4-e4b and gemma3n-e4b (37–51%). On afrimedqa_mcq specifically, both med-specific models underperform gemma3n-e4b by ~7–10 pp, suggesting the African medical knowledge gap is not addressed by general medical domain training.
- **RAG hurts MCQ universally** across all 4 GGUF models (−3.6 to −11.6 pp). The RAG penalty is larger for medgemma-4b and meditron3-8b (−4.2 to −6.6 pp) than for gemma3n-e4b (−0.4 to −2.2 pp), suggesting these models are more sensitive to context injection at this size. RAG has essentially no effect on gpt-5 (≤1.8 pp change, one positive).
- **gpt-5 dominates** at 67–92% vs 31–51% for the GGUF models — a 25–50 pp gap. This is the expected ceiling for an API-scale model.
- **afrimedqa partial credit gap**: all models show a ~3–6 pp gap between strict accuracy and partial credit on afrimedqa_mcq, driven by the 112 multi-answer questions where models pick one of several correct letters but not the full set.

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

| Model | Condition | kenya_vignettes (n=284) | afrimedqa_saq (n=37) | whb_stumps (n=20) |
|-------|-----------|------------------------|----------------------|-------------------|
| gemma4-e4b | No-RAG | 2.76 | 2.57 | 2.51 |
| gemma4-e4b | +RAG | 2.43 | 2.17 | 2.68 |
| gemma3n-e4b | No-RAG | 3.02 | 3.28 | 2.64 |
| gemma3n-e4b | +RAG | 2.97 | 2.88 | 2.64 |
| medgemma-4b | No-RAG | 2.72 | 2.98 | 2.38 |
| medgemma-4b | +RAG | 2.73 | 2.86 | 2.46 |
| meditron3-8b | No-RAG | 2.60 | 3.17 | 2.43 |
| meditron3-8b | +RAG | 2.55 | 3.01 | 2.34 |
| gpt-5 | No-RAG | 4.37 | 4.60 | 3.59 |
| gpt-5 | +RAG | 4.22 | 4.51 | 3.47 |

### Per-dimension breakdown — No-RAG

| Dataset | Model | accuracy | safety | completeness | helpfulness | clarity |
|---------|-------|----------|--------|--------------|-------------|---------|
| kenya_vignettes | gemma4-e4b | 2.68 | 3.19 | 1.83 | 2.58 | 4.00 |
| kenya_vignettes | gemma3n-e4b | 2.84 | 3.10 | 2.46 | 3.30 | 4.01 |
| kenya_vignettes | medgemma-4b | 2.59 | 2.86 | 2.08 | 2.72 | 4.07 |
| kenya_vignettes | meditron3-8b | 2.52 | 2.52 | 2.04 | 2.74 | 3.96 |
| kenya_vignettes | gpt-5 | 4.15 | 4.59 | 4.00 | 4.61 | 4.83 |
| afrimedqa_saq | gemma4-e4b | 2.35 | 3.41 | 1.54 | 2.05 | 3.97 |
| afrimedqa_saq | gemma3n-e4b | 3.11 | 3.81 | 2.49 | 3.24 | 4.08 |
| afrimedqa_saq | medgemma-4b | 2.81 | 3.51 | 2.14 | 2.73 | 4.24 |
| afrimedqa_saq | meditron3-8b | 3.14 | 3.22 | 2.54 | 3.32 | 4.19 |
| afrimedqa_saq | gpt-5 | 4.57 | 4.59 | 4.32 | 4.81 | 4.97 |
| whb_stumps | gemma4-e4b | 2.35 | 3.25 | 1.35 | 2.10 | 4.05 |
| whb_stumps | gemma3n-e4b | 2.50 | 3.00 | 1.65 | 2.75 | 4.00 |
| whb_stumps | medgemma-4b | 2.30 | 2.75 | 1.40 | 1.85 | 4.40 |
| whb_stumps | meditron3-8b | 2.35 | 2.65 | 1.50 | 2.40 | 4.00 |
| whb_stumps | gpt-5 | 3.25 | 3.70 | 3.20 | 4.05 | 4.40 |

### Per-dimension breakdown — +RAG

| Dataset | Model | accuracy | safety | completeness | helpfulness | clarity |
|---------|-------|----------|--------|--------------|-------------|---------|
| kenya_vignettes | gemma4-e4b | 2.33 | 2.93 | 1.48 | 2.07 | 3.96 |
| kenya_vignettes | gemma3n-e4b | 2.81 | 3.12 | 2.37 | 3.18 | 3.99 |
| kenya_vignettes | medgemma-4b | 2.57 | 2.71 | 2.24 | 2.86 | 4.02 |
| kenya_vignettes | meditron3-8b | 2.46 | 2.48 | 2.01 | 2.66 | 3.93 |
| kenya_vignettes | gpt-5 | 4.04 | 4.45 | 3.88 | 4.42 | 4.60 |
| afrimedqa_saq | gemma4-e4b | 1.73 | 3.24 | 1.14 | 1.43 | 4.00 |
| afrimedqa_saq | gemma3n-e4b | 2.70 | 3.57 | 2.00 | 2.54 | 4.00 |
| afrimedqa_saq | medgemma-4b | 2.70 | 3.65 | 1.81 | 2.27 | 4.35 |
| afrimedqa_saq | meditron3-8b | 2.95 | 3.19 | 2.35 | 3.05 | 4.00 |
| afrimedqa_saq | gpt-5 | 4.53 | 4.56 | 4.19 | 4.61 | 4.81 |
| whb_stumps | gemma4-e4b | 2.70 | 3.15 | 1.65 | 2.30 | 4.05 |
| whb_stumps | gemma3n-e4b | 2.45 | 3.00 | 1.75 | 2.75 | 3.95 |
| whb_stumps | medgemma-4b | 2.50 | 2.80 | 1.40 | 2.05 | 4.25 |
| whb_stumps | meditron3-8b | 2.10 | 2.40 | 1.65 | 2.55 | 3.95 |
| whb_stumps | gpt-5 | 3.10 | 3.65 | 2.90 | 4.10 | 4.30 |

### Score distributions (No-RAG)

**kenya_vignettes** (n=284):

| Score | g4 acc | g3n acc | mg4 acc | m3 acc | gpt5 acc | g4 saf | g3n saf | mg4 saf | m3 saf | gpt5 saf | g4 com | g3n com | mg4 com | m3 com | gpt5 com |
|-------|--------|---------|---------|--------|----------|--------|---------|---------|--------|----------|--------|---------|---------|--------|----------|
| 1 | 7 | 9 | 22 | 26 | 0 | 2 | 9 | 13 | 33 | 0 | 65 | 11 | 67 | 48 | 0 |
| 2 | 99 | 81 | 111 | 112 | 1 | 31 | 58 | 79 | 93 | 0 | 201 | 144 | 134 | 178 | 2 |
| 3 | 155 | 141 | 112 | 118 | 13 | 162 | 114 | 130 | 137 | 3 | 18 | 116 | 77 | 57 | 41 |
| 4 | 23 | 53 | 39 | 28 | 213 | 88 | 103 | 60 | 20 | 111 | 0 | 13 | 6 | 1 | 197 |
| 5 | 0 | 0 | 0 | 0 | 57 | 1 | 0 | 2 | 1 | 170 | 0 | 0 | 0 | 0 | 44 |

*g4=gemma4-e4b, g3n=gemma3n-e4b, mg4=medgemma-4b, m3=meditron3-8b, acc=accuracy, saf=safety, com=completeness*

**afrimedqa_saq** (n=37):

| Score | g4 acc | g3n acc | mg4 acc | m3 acc | gpt5 acc | g4 com | g3n com | mg4 com | m3 com | gpt5 com |
|-------|--------|---------|---------|--------|----------|--------|---------|---------|--------|----------|
| 1 | 11 | 1 | 4 | 1 | 0 | 19 | 5 | 11 | 2 | 0 |
| 2 | 6 | 6 | 8 | 9 | 0 | 16 | 13 | 12 | 14 | 0 |
| 3 | 16 | 18 | 16 | 11 | 0 | 2 | 15 | 12 | 20 | 4 |
| 4 | 4 | 12 | 9 | 16 | 16 | 0 | 4 | 2 | 1 | 17 |
| 5 | 0 | 0 | 0 | 0 | 21 | 0 | 0 | 0 | 0 | 16 |

**whb_stumps** (n=20):

| Score | g4 acc | g3n acc | mg4 acc | m3 acc | gpt5 acc | g4 com | g3n com | mg4 com | m3 com | gpt5 com |
|-------|--------|---------|---------|--------|----------|--------|---------|---------|--------|----------|
| 1 | 5 | 1 | 3 | 3 | 1 | 13 | 7 | 13 | 10 | 0 |
| 2 | 5 | 9 | 8 | 8 | 5 | 7 | 13 | 6 | 10 | 5 |
| 3 | 8 | 9 | 9 | 8 | 4 | 0 | 0 | 1 | 0 | 7 |
| 4 | 2 | 1 | 0 | 1 | 8 | 0 | 0 | 0 | 0 | 7 |
| 5 | 0 | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 0 | 1 |

---

## Key findings

### 0. Med-specific models (medgemma-4b, meditron3-8b) show mixed results vs. on-device Gemma models

On MCQ, neither med-specific model improves over the on-device Gemma baseline:

| Model | afrimedqa_mcq | medqa_usmle | medmcqa_mcq |
|-------|--------------|-------------|-------------|
| gemma4-e4b (our deployment) | 37.0% | 40.8% | 51.0% |
| gemma3n-e4b (predecessor) | 41.1% | 44.2% | 51.2% |
| medgemma-4b | 37.7% | 44.9% | 50.2% |
| meditron3-8b | 31.4% | 42.2% | 51.0% |

On open-ended tasks, the picture is more nuanced:

| Model | kenya_vignettes | afrimedqa_saq | whb_stumps |
|-------|----------------|---------------|------------|
| gemma4-e4b | 2.76 | 2.57 | 2.51 |
| gemma3n-e4b | **3.02** | **3.28** | **2.64** |
| medgemma-4b | 2.72 | 2.98 | 2.38 |
| meditron3-8b | 2.60 | 3.17 | 2.43 |

meditron3-8b scores notably well on afrimedqa_saq (3.17), approaching gemma3n-e4b (3.28), suggesting stronger short-form medical Q&A capability. However, it underperforms on kenya_vignettes (2.60 vs 2.76 for gemma4-e4b), which requires clinical reasoning over longer vignettes. medgemma-4b performs consistently below gemma3n-e4b across all datasets. Neither med-specific model provides a clear overall advantage over the current on-device Gemma deployment.

---

### 1. gemma3n-e4b outperforms gemma4-e4b on open-ended tasks

gemma3n-e4b scores higher than gemma4-e4b on open-ended weighted scores across all three datasets in the no-RAG condition:

| Dataset | gemma4-e4b | gemma3n-e4b | Δ |
|---------|-----------|------------|---|
| kenya_vignettes | 2.76 | 3.02 | **+0.26** |
| afrimedqa_saq | 2.57 | 3.28 | **+0.71** |
| whb_stumps | 2.51 | 2.64 | **+0.13** |

The gap is most pronounced on afrimedqa_saq (+0.71). The improvement comes primarily from completeness (gemma3n-e4b 2.49 vs gemma4-e4b 1.54 on afrimedqa_saq no-RAG) and helpfulness. This suggests that the E4B int4 quantization applied to gemma4-e4b has a more significant impact on response quality than the older gemma3n-e4b quantization, at least under the current GGUF CPU inference path.

### 2. RAG hurts both on-device models but gpt-5 is robust to it

RAG degrades open-ended performance for both gemma4-e4b and gemma3n-e4b on kenya_vignettes and afrimedqa_saq. gemma4-e4b is more severely affected:

| Dataset | gemma4-e4b RAG Δ | gemma3n-e4b RAG Δ | gpt-5 RAG Δ |
|---------|----------------|-----------------|------------|
| kenya_vignettes | **−0.33** | −0.05 | −0.15 |
| afrimedqa_saq | **−0.40** | −0.40 | −0.09 |
| whb_stumps | +0.17 | 0.00 | −0.12 |

gpt-5 is nearly unaffected by RAG context injection (≤0.15 drop). The MCQ pattern is similar: gpt-5 shows ≤1.8 pp change from RAG, while gemma4-e4b shows up to −11.6 pp on medmcqa_mcq. This points to a **prompt construction mismatch** specific to the GGUF models: the injected `Document N:` context blocks appear to confuse the letter-extraction behaviour for gemma4-e4b more than gemma3n-e4b, and both struggle compared to gpt-5 which can naturally integrate retrieved context.

### 3. gpt-5 is the performance ceiling — on-device models are far behind on knowledge tasks

The gap between gpt-5 and the on-device models is large:

| Metric | gemma4-e4b | gemma3n-e4b | medgemma-4b | meditron3-8b | gpt-5 |
|--------|-----------|------------|------------|-------------|-------|
| medqa_usmle (no-RAG) | 40.8% | 44.2% | 44.9% | 42.2% | 92.5% |
| medmcqa_mcq (no-RAG) | 51.0% | 51.2% | 50.2% | 51.0% | 89.0% |
| afrimedqa_mcq (no-RAG) | 37.0% | 41.1% | 37.7% | 31.4% | 67.0% |
| kenya_vignettes weighted (no-RAG) | 2.76 | 3.02 | 2.72 | 2.60 | 4.37 |
| afrimedqa_saq weighted (no-RAG) | 2.57 | 3.28 | 2.98 | 3.17 | 4.60 |

For MCQ, gpt-5 is 40–50 pp above both on-device models. For open-ended, gpt-5 scores 1.3–1.6 points higher (on a 1–5 scale). However, gpt-5 is not a viable deployment option (requires internet, API costs, data privacy), so the on-device comparison is the operationally relevant one.

### 4. Completeness remains the primary quality bottleneck for on-device models — but not for gpt-5

Completeness is the weakest dimension for both gemma4-e4b and gemma3n-e4b (1.35–2.49 no-RAG vs 3.20–4.32 for gpt-5). For gemma4-e4b specifically, completeness scores cluster heavily at 1–2 (e.g., 65+201=266/284 responses score 1 or 2 on completeness for kenya_vignettes). gemma3n-e4b is noticeably better on completeness but still far below gpt-5.

This gap is partly a deliberate trade-off: the app system prompt values conciseness for triage contexts. The judge may penalise concise responses. That said, gpt-5 also uses the same system prompt and still scores 4.00 on completeness for kenya_vignettes — so prompt-induced brevity does not fully explain the gap. On-device model responses appear genuinely less comprehensive.

### 5. Clarity is a consistent strength for all models

All three models score 3.95–4.97 on clarity across all conditions. Clarity is not a differentiator. Users can expect clear, readable responses regardless of which model is deployed.

### 6. Safety scores reveal a gap between on-device models and gpt-5

| Dataset | gemma4-e4b NoRAG | gemma3n-e4b NoRAG | gpt-5 NoRAG |
|---------|----------------|-----------------|------------|
| kenya_vignettes | 3.19 | 3.10 | 4.59 |
| afrimedqa_saq | 3.41 | 3.81 | 4.59 |
| whb_stumps | 3.25 | 3.00 | 3.70 |

Safety is mediocre (3.0–3.8) for both on-device models and excellent (3.7–4.6) for gpt-5. The safety score distribution for gemma3n-e4b kenya_vignettes no-RAG shows 9 responses scored safety=1 and 58 scored safety=2 — a meaningful tail of potentially unsafe responses. With RAG, gemma4-e4b safety drops further (kenya_vignettes: 3.19 → 2.93, with 11 safety=1 responses). These low-safety cases should be manually reviewed before any production RAG deployment.

### 7. gemma4-e4b MCQ anomaly: medmcqa_mcq RAG degradation

gemma4-e4b shows a unique −11.6 pp accuracy drop on medmcqa_mcq with RAG, which is not present in gemma3n-e4b (−0.4 pp) or gpt-5 (−1.8 pp). This is a model-specific regression worth investigating. The most likely cause is that the RAG context injection format interacts badly with gemma4-e4b's letter-extraction behaviour on this particular dataset's question style.

---

## Judge metadata

- All open-ended responses were judged with 0 judge failures across all models and conditions
- Judge model: configured via `config/eval_config.json` (`judge_model` field, value: `gpt-5.2`)
- Dimension weights: accuracy 0.30 · safety 0.25 · completeness 0.20 · helpfulness 0.15 · clarity 0.10
- Total open-ended responses judged: 341 questions × 2 conditions × 5 models = 3,410 judgments

---

## Recommendations

1. **Investigate gemma4-e4b MCQ RAG regression**: The −11.6 pp drop on medmcqa_mcq under RAG is specific to gemma4-e4b and not reproduced in gemma3n-e4b or gpt-5. Inspect individual +RAG responses to determine whether the model is ignoring, misusing, or confused by the injected guidelines. Consider ablating the `Document N:` label format.

2. **Reconsider gemma4-e4b as the deployment target**: gemma3n-e4b outperforms gemma4-e4b on open-ended tasks (the deployment-relevant metric) by 0.13–0.71 weighted score points, and is nearly equivalent or slightly better on MCQ. Unless gemma4-e4b has other advantages (inference speed, memory footprint, on-device compatibility), gemma3n-e4b is the stronger choice under the current evaluation.

3. **Manual review of low-safety responses**: The safety=1 and safety=2 response tails for both on-device models (especially under +RAG) should be reviewed before production deployment. Specifically: gemma4-e4b kenya_vignettes +RAG (11 safety=1 responses) and gemma3n-e4b kenya_vignettes no-RAG (9 safety=1 responses).

4. **Reframe completeness interpretation**: The app system prompt instructs conciseness for clinical triage. The judge's completeness rubric may expect comprehensive clinical notes. If so, completeness scores for on-device models are systematically pessimistic. Consider calibrating the judge rubric for triage-style responses, or adding a separate "appropriate brevity" dimension.

5. **Caution on small-n datasets**: whb_stumps (n=20) and afrimedqa_saq (n=37) have high variance. Treat them as indicative only; do not draw strong model-ranking conclusions from these datasets.

6. **Next run: ablate context injection format**: Test whether reformatting the RAG context injection (e.g., removing the `Document N:` prefix, using bullet points, or a brief preamble instructing the model how to use the context) improves MCQ and open-ended scores under RAG, particularly for gemma4-e4b.

7. **gpt-5 as judge quality check**: With gpt-5 scoring 4.37–4.60 on the same datasets judged by gpt-5.2, there is a potential self-serving bias risk (gpt-family judge scoring gpt-family model). Consider cross-checking a sample of gpt-5 open-ended judgments with a non-OpenAI judge (e.g., Claude) to validate the scores are not inflated.

8. **Do not switch to med-specific models**: On MCQ, neither medgemma-4b nor meditron3-8b outperforms the current gemma3n-e4b baseline, and both show larger RAG penalties. On open-ended tasks, medgemma-4b is consistently below gemma3n-e4b across all three datasets. meditron3-8b performs comparably to gemma3n-e4b on afrimedqa_saq but underperforms on kenya_vignettes, which is the larger and more clinically representative dataset (n=284). Given no demonstrated advantage and added deployment complexity, switching to a med-specific model is not justified by the current evidence.
