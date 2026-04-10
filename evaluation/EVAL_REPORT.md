# MAM-AI Model Evaluation Report

## Setup

**Models evaluated**:
- **Gemma 4 E4B-IT** (Q4_0 GGUF) — current deployed model, **MCQ only so far**
- **Gemma 3n E4B-IT** (4.1 GB, Q4_0 GGUF) — deployed in the MAM-AI app
- **Gemma 3n E2B-IT** (2.8 GB, Q4_0 GGUF) — smaller variant
- **MedGemma 4B-IT** (2.3 GB, Q4_0 GGUF) — medical-domain finetuned
- **Meditron3 8B** (4.7 GB, Q4_0 GGUF) — medical-domain finetuned (Llama 3.1 base)
- **GPT-5** (OpenAI API) — cloud baseline

On-device models run via llama-cpp-python with CUDA on an NVIDIA A100. GPT-5 via OpenAI API.

**RAG**: Top-3 chunks retrieved via Gecko embeddings from 2,826 pre-embedded medical guideline chunks (same pipeline as the on-device app).

**Benchmarks** (6 datasets):
- *MCQ* (accuracy): AfriMedQA MCQ (660), MedQA USMLE (1,025), MedMCQA (500)
- *Open-ended* (LLM-as-judge, 1–5): Kenya Vignettes (284), AfriMedQA SAQ (37), WHB Stumps (20)

**Judge**: GPT-5.2 scoring on 5 weighted dimensions — accuracy (30%), safety (25%), completeness (20%), helpfulness (15%), clarity (10%).

---

## Results

### MCQ Benchmarks (accuracy %)

| Model | AfriMedQA | MedQA USMLE | MedMCQA | Avg |
|---|:---:|:---:|:---:|:---:|
| GPT-5 | **65.2** | 91.3 | 86.2 | 80.9 |
| GPT-5 + RAG | 64.8 | **91.6** | **86.4** | **80.9** |
| Gemma 4 E4B† | 37.0 | 40.8 | 51.0 | 42.9 |
| Gemma E4B | 40.8 | 44.1 | 51.8 | 45.6 |
| Gemma E4B + RAG | 38.2 | 41.8 | 50.2 | 43.4 |
| MedGemma 4B | 37.6 | 44.8 | 51.0 | 44.5 |
| MedGemma + RAG | 32.9 | 40.8 | 44.6 | 39.4 |
| Meditron3 8B | 31.4 | 41.1 | 50.6 | 41.0 |
| Meditron3 + RAG | 28.2 | 37.1 | 39.8 | 35.0 |
| Gemma E2B | 37.4 | 39.8 | 47.0 | 41.4 |
| Gemma E2B + RAG | 32.7 | 37.5 | 41.4 | 37.2 |

*†Gemma 4 E4B has only been evaluated on the three MCQ benchmarks so far. Open-ended evaluation is still pending.*

### Open-ended Benchmarks (weighted judge score /5)

| Model | Kenya Vignettes | AfriMedQA SAQ | WHB Stumps | Avg |
|---|:---:|:---:|:---:|:---:|
| GPT-5† | **4.69** | **4.78** | **3.93** | **4.47** |
| GPT-5 + RAG† | 4.70 | 4.72 | 3.86 | 4.43 |
| Gemma E4B | 3.11 | 3.39 | 2.68 | 3.06 |
| Gemma E4B + RAG | 3.08 | 3.48 | 2.67 | 3.08 |
| MedGemma 4B | 2.93 | 3.22 | 2.54 | 2.90 |
| MedGemma + RAG | 2.93 | 3.09 | 2.77 | 2.93 |
| Meditron3 8B | 2.76 | 3.34 | 2.55 | 2.88 |
| Meditron3 + RAG | 2.68 | 3.11 | 2.32 | 2.70 |
| Gemma E2B | 2.75 | 2.95 | 2.58 | 2.76 |
| Gemma E2B + RAG | 2.73 | 2.91 | 2.39 | 2.68 |

*†GPT-5 Kenya Vignettes: partial (31–32/284 questions, API quota exhausted). SAQ and WHB Stumps are complete.*

### Per-Dimension Breakdown (open-ended, without RAG)

Each response is scored 1–5 on five dimensions. Weighted = accuracy (30%) + safety (25%) + completeness (20%) + helpfulness (15%) + clarity (10%).

#### Kenya Vignettes (n=284; GPT-5 n=31†)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5† | **4.41** | **4.66** | **4.79** | **5.00** | **4.97** | **4.69** |
| Gemma E4B | 2.75 | 2.70 | 3.30 | 3.64 | 4.02 | 3.11 |
| MedGemma 4B | 2.57 | 2.44 | 3.17 | 3.45 | 3.96 | 2.93 |
| Meditron3 8B | 2.64 | 2.54 | 2.36 | 3.10 | 3.97 | 2.76 |
| Gemma E2B | 2.38 | 2.30 | 2.93 | 3.23 | 3.96 | 2.75 |

#### AfriMedQA SAQ (n=37)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5 | **4.81** | **4.62** | **4.70** | **4.92** | **5.00** | **4.78** |
| Gemma E4B | 2.81 | 3.43 | 3.49 | 3.89 | 4.08 | 3.39 |
| Meditron3 8B | 3.24 | 3.27 | 2.89 | 3.68 | 4.19 | 3.34 |
| MedGemma 4B | 2.62 | 3.24 | 3.41 | 3.57 | 4.05 | 3.22 |
| Gemma E2B | 2.41 | 2.86 | 3.08 | 3.32 | 3.97 | 2.95 |

#### WHB Stumps (n=20)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5 | **3.45** | **3.85** | **3.85** | **4.65** | **4.65** | **3.93** |
| Gemma E4B | 2.25 | 2.50 | 2.30 | 3.45 | 4.00 | 2.68 |
| Gemma E2B | 2.05 | 2.40 | 2.35 | 3.30 | 3.95 | 2.58 |
| Meditron3 8B | 2.30 | 2.40 | 2.05 | 3.00 | 4.00 | 2.55 |
| MedGemma 4B | 2.15 | 2.25 | 2.30 | 3.15 | 4.00 | 2.54 |

### Per-Dimension Breakdown (open-ended, with RAG)

#### Kenya Vignettes (n=284; GPT-5 n=32†)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5† | **4.43** | **4.60** | **4.83** | **5.00** | **5.00** | **4.70** |
| Gemma E4B | 2.73 | 2.77 | 3.15 | 3.61 | 4.02 | 3.08 |
| MedGemma 4B | 2.60 | 2.50 | 3.09 | 3.44 | 3.98 | 2.93 |
| Gemma E2B | 2.35 | 2.34 | 2.79 | 3.21 | 3.97 | 2.73 |
| Meditron3 8B | 2.55 | 2.51 | 2.25 | 2.96 | 3.95 | 2.68 |

#### AfriMedQA SAQ (n=37)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5 | **4.70** | **4.57** | **4.65** | **4.95** | **4.92** | **4.72** |
| Gemma E4B | 3.11 | 3.57 | 3.38 | 3.70 | 4.27 | 3.48 |
| Meditron3 8B | 2.97 | 3.14 | 2.51 | 3.43 | 4.14 | 3.11 |
| MedGemma 4B | 2.62 | 3.11 | 3.05 | 3.43 | 3.97 | 3.09 |
| Gemma E2B | 2.38 | 3.05 | 2.76 | 3.24 | 3.95 | 2.91 |

#### WHB Stumps (n=20)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5 | **3.25** | **3.85** | **3.80** | **4.55** | **4.75** | **3.86** |
| MedGemma 4B | 2.35 | 2.65 | 2.40 | 3.45 | 4.00 | 2.77 |
| Gemma E4B | 2.15 | 2.65 | 2.20 | 3.50 | 4.00 | 2.67 |
| Gemma E2B | 1.90 | 2.25 | 2.00 | 3.10 | 3.95 | 2.39 |
| Meditron3 8B | 2.00 | 2.10 | 1.80 | 2.95 | 3.95 | 2.32 |

*†GPT-5 Kenya Vignettes results are partial (31–32/284 questions) due to API quota exhaustion.*

### Cross-Model Dimension Averages (without RAG)

Averaged across all three open-ended benchmarks:

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5† | **4.22** | **4.38** | **4.45** | **4.86** | **4.87** | **4.47** |
| Gemma E4B | 2.60 | 2.88 | 3.03 | 3.66 | 4.03 | 3.06 |
| MedGemma 4B | 2.45 | 2.64 | 2.96 | 3.39 | 4.00 | 2.90 |
| Meditron3 8B | 2.73 | 2.74 | 2.43 | 3.26 | 4.05 | 2.88 |
| Gemma E2B | 2.28 | 2.52 | 2.79 | 3.28 | 3.96 | 2.76 |

GPT-5 scores ~4.5/5 across all dimensions — a large gap over on-device models (~3.0/5). Among on-device models: **Clarity (~4.0) > Helpfulness (~3.3) > Completeness (~2.8) > Safety (~2.7) > Accuracy (~2.5)**. All on-device models produce well-structured responses but struggle with factual accuracy and clinical safety.

---

## Key Insights

### 1. RAG hurts more than it helps

Every on-device model sees **degraded MCQ accuracy** with RAG context (-2.2pp to -6.0pp). GPT-5 is unaffected on MCQ but drops slightly on open-ended (4.47 → 4.43). On open-ended benchmarks, RAG effects are small and mixed across all models. The retrieved OBGYN guidelines appear to distract smaller models rather than ground their answers.

| Model | NoRAG MCQ Avg | +RAG MCQ Avg | Delta |
|---|:---:|:---:|:---:|
| GPT-5 | 80.9% | 80.9% | 0.0 |
| Gemma 4 E4B† | 42.9% | — | — |
| Gemma E4B | 45.6% | 43.4% | -2.2 |
| MedGemma 4B | 44.5% | 39.4% | -5.1 |
| Meditron3 8B | 41.0% | 35.0% | -6.0 |
| Gemma E2B | 41.4% | 37.2% | -4.2 |

### 2. The "fluency trap" — high clarity masks low accuracy

For on-device models, **clarity scores ~4.0/5** even when accuracy is 1–2/5. The models write convincingly when factually wrong — dangerous for medical applications where users may trust well-articulated but incorrect advice. GPT-5 does not exhibit this: its clarity (~4.9) is backed by high accuracy (~4.2).

### 3. Gemma 4 E4B does not beat Gemma 3n E4B on MCQ quality

Gemma 4 E4B scores **42.9% average MCQ accuracy**, below Gemma 3n E4B's **45.6%** by **2.7 percentage points**. Its strongest result is MedMCQA (51.0%), where it matches MedGemma 4B, but it underperforms Gemma 3n E4B on AfriMedQA (37.0% vs 40.8%) and MedQA USMLE (40.8% vs 44.1%).

Among models with full MCQ + open-ended evaluation, **Gemma 3n E4B remains the strongest on-device model overall**. On MCQ-only results, Gemma 4 E4B ranks below Gemma 3n E4B and MedGemma 4B, and above Gemma 3n E2B and Meditron3 8B.

### 4. GPT-5 is the quality ceiling

GPT-5 scores 4.47/5 on open-ended vs 3.06/5 for Gemma E4B — a **1.4-point gap**. On MCQ: 80.9% vs 45.6%. This quantifies the accuracy cost of on-device inference. The gap is largest on accuracy (4.22 vs 2.60) and smallest on clarity (4.87 vs 4.03).

*Note: An initial GPT-5 run produced empty open-ended responses due to a `max_completion_tokens` budget issue with reasoning tokens. Fixed by removing the token cap. Kenya Vignettes results are partial (31–32/284) due to API quota exhaustion.*

### 5. Medical finetuning provides limited benefit at this scale

MedGemma and Meditron3, despite medical-domain finetuning, do not consistently outperform general-purpose Gemma E4B. Meditron3 at 8B parameters underperforms the 4B E4B. At Q4_0 quantization, instruction-following capability matters more than domain-specific pretraining.

### 6. AfriMedQA is the hardest benchmark

All models score lowest on AfriMedQA MCQ (28–65%), reflecting African clinical contexts underrepresented in training data — particularly relevant for MAM-AI's deployment in Zanzibar.

---

## Recommendations

1. **Do not justify the model switch on MCQ quality alone.** Gemma 4 E4B improves neither average MCQ accuracy nor headline benchmark performance versus Gemma 3n E4B (42.9% vs 45.6%).

2. **Keep Gemma 3n E4B as the quality baseline** until Gemma 4 E4B's open-ended evaluation is complete and there is a clear reason to prefer it despite the CPU TTFT regression.

3. **Complete Gemma 4 E4B open-ended evaluation** before making a final deployment call. MCQ results alone are not enough to rule in or rule out Gemma 4 for clinical use.

4. **Improve RAG retrieval quality** — current pipeline degrades accuracy for all evaluated on-device models. Options: raise similarity threshold, improve chunk relevance filtering, or only inject context above a confidence threshold.

5. **Address the fluency trap** — on-device models score ~4.0 clarity with ~2.5 accuracy. Consider adding uncertainty signals so users don't over-trust well-written but inaccurate responses.

6. **E2B is viable for constrained devices** — at 2.8 GB (vs 4.1 GB), it retains ~90% of E4B's performance.

7. **Complete GPT-5 Kenya Vignettes** — only 31/284 questions evaluated. Top up API credits and re-run; `--run-dir` auto-resume will continue from the checkpoint.
