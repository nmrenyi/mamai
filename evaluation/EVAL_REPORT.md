# MAM-AI Model Evaluation Report

## Setup

**Models evaluated** (all Q4_0 quantized GGUF, run via llama-cpp-python with CUDA):
- **Gemma 3n E4B-IT** (4.1 GB) — deployed in the MAM-AI app
- **Gemma 3n E2B-IT** (2.8 GB) — smaller variant
- **MedGemma 4B-IT** (2.3 GB) — medical-domain finetuned
- **Meditron3 8B** (4.7 GB) — medical-domain finetuned (Llama 3.1 base)
- **GPT-5** (API) — cloud baseline

**RAG configuration**: Top-3 chunks retrieved via Gecko embeddings from 2,826 pre-embedded medical guideline chunks (same pipeline as the on-device app).

**Benchmarks** (6 datasets, 2 types):
- *MCQ* (accuracy): AfriMedQA MCQ (660), MedQA USMLE (1,025), MedMCQA (500)
- *Open-ended* (LLM-as-judge, 1-5 scale): Kenya Vignettes (284), AfriMedQA SAQ (37), WHB Stumps (20)

**Judge**: GPT-5.2 scoring on 5 weighted dimensions: accuracy (30%), safety (25%), completeness (20%), helpfulness (15%), clarity (10%).

---

## Results

### MCQ Benchmarks (accuracy %)

| Model | AfriMedQA | MedQA USMLE | MedMCQA | Avg |
|---|:---:|:---:|:---:|:---:|
| GPT-5 | 65.2 | 91.3 | 86.2 | 80.9 |
| GPT-5 + RAG | 64.8 | **91.6** | **86.4** | **80.9** |
| Gemma E4B | **40.8** | 44.1 | **51.8** | **45.6** |
| Gemma E4B + RAG | 38.2 | 41.8 | 50.2 | 43.4 |
| MedGemma 4B | 37.6 | **44.8** | 51.0 | 44.5 |
| MedGemma + RAG | 32.9 | 40.8 | 44.6 | 39.4 |
| Meditron3 8B | 31.4 | 41.1 | 50.6 | 41.0 |
| Meditron3 + RAG | 28.2 | 37.1 | 39.8 | 35.0 |
| Gemma E2B | 37.4 | 39.8 | 47.0 | 41.4 |
| Gemma E2B + RAG | 32.7 | 37.5 | 41.4 | 37.2 |

### Open-ended Benchmarks (weighted judge score /5)

| Model | Kenya Vignettes | AfriMedQA SAQ | WHB Stumps | Avg |
|---|:---:|:---:|:---:|:---:|
| GPT-5* | — | 1.63 | 1.48 | — |
| GPT-5 + RAG* | — | 2.23 | 1.22 | — |
| Gemma E4B | **3.11** | 3.39 | **2.68** | **3.06** |
| Gemma E4B + RAG | 3.08 | **3.48** | 2.67 | **3.08** |
| MedGemma 4B | 2.93 | 3.22 | 2.54 | 2.90 |
| MedGemma + RAG | 2.93 | 3.09 | **2.77** | 2.93 |
| Meditron3 8B | 2.76 | **3.34** | 2.55 | 2.88 |
| Meditron3 + RAG | 2.68 | 3.11 | 2.32 | 2.70 |
| Gemma E2B | 2.75 | 2.95 | 2.58 | 2.76 |
| Gemma E2B + RAG | 2.73 | 2.91 | 2.39 | 2.68 |

*\*GPT-5 open-ended scores are invalid — see [Insight 5](#5-gpt-5-open-ended-generation-failed).*

### Per-Dimension Breakdown (open-ended, without RAG)

Each open-ended response is scored 1-5 on five clinical dimensions. The weighted score combines them as: accuracy (30%) + safety (25%) + completeness (20%) + helpfulness (15%) + clarity (10%).

#### Kenya Vignettes (n=284)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Gemma E4B | **2.75** | **2.70** | **3.30** | **3.64** | **4.02** | **3.11** |
| MedGemma 4B | 2.57 | 2.44 | 3.17 | 3.45 | 3.96 | 2.93 |
| Meditron3 8B | 2.64 | 2.54 | 2.36 | 3.10 | 3.97 | 2.76 |
| Gemma E2B | 2.38 | 2.30 | 2.93 | 3.23 | 3.96 | 2.75 |

#### AfriMedQA SAQ (n=37)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Gemma E4B | 2.81 | **3.43** | **3.49** | **3.89** | 4.08 | 3.39 |
| Meditron3 8B | **3.24** | 3.27 | 2.89 | 3.68 | **4.19** | **3.34** |
| MedGemma 4B | 2.62 | 3.24 | 3.41 | 3.57 | 4.05 | 3.22 |
| Gemma E2B | 2.41 | 2.86 | 3.08 | 3.32 | 3.97 | 2.95 |

#### WHB Stumps (n=20)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Gemma E4B | **2.25** | **2.50** | **2.30** | **3.45** | 4.00 | **2.68** |
| Gemma E2B | 2.05 | 2.40 | 2.35 | 3.30 | 3.95 | 2.58 |
| Meditron3 8B | 2.30 | 2.40 | 2.05 | 3.00 | **4.00** | 2.55 |
| MedGemma 4B | 2.15 | 2.25 | 2.30 | 3.15 | **4.00** | 2.54 |

### Per-Dimension Breakdown (open-ended, with RAG)

#### Kenya Vignettes (n=284)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Gemma E4B | **2.73** | **2.77** | **3.15** | **3.61** | **4.02** | **3.08** |
| MedGemma 4B | 2.60 | 2.50 | 3.09 | 3.44 | 3.98 | 2.93 |
| Gemma E2B | 2.35 | 2.34 | 2.79 | 3.21 | 3.97 | 2.73 |
| Meditron3 8B | 2.55 | 2.51 | 2.25 | 2.96 | 3.95 | 2.68 |

#### AfriMedQA SAQ (n=37)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Gemma E4B | **3.11** | **3.57** | **3.38** | **3.70** | **4.27** | **3.48** |
| Meditron3 8B | 2.97 | 3.14 | 2.51 | 3.43 | 4.14 | 3.11 |
| MedGemma 4B | 2.62 | 3.11 | 3.05 | 3.43 | 3.97 | 3.09 |
| Gemma E2B | 2.38 | 3.05 | 2.76 | 3.24 | 3.95 | 2.91 |

#### WHB Stumps (n=20)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| MedGemma 4B | **2.35** | **2.65** | **2.40** | **3.45** | **4.00** | **2.77** |
| Gemma E4B | 2.15 | **2.65** | 2.20 | 3.50 | **4.00** | 2.67 |
| Gemma E2B | 1.90 | 2.25 | 2.00 | 3.10 | 3.95 | 2.39 |
| Meditron3 8B | 2.00 | 2.10 | 1.80 | 2.95 | 3.95 | 2.32 |

### Cross-Model Dimension Averages (without RAG)

Averaging across all three open-ended benchmarks:

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Gemma E4B | **2.60** | **2.88** | **3.03** | **3.66** | **4.03** | **3.06** |
| MedGemma 4B | 2.45 | 2.64 | 2.96 | 3.39 | 4.00 | 2.90 |
| Meditron3 8B | 2.73 | 2.74 | 2.43 | 3.26 | 4.05 | 2.88 |
| Gemma E2B | 2.28 | 2.52 | 2.79 | 3.28 | 3.96 | 2.76 |

A consistent hierarchy emerges across all models: **Clarity (~4.0) > Helpfulness (~3.3) > Completeness (~2.8) > Safety (~2.7) > Accuracy (~2.5)**. All models produce well-structured responses but struggle with factual accuracy and clinical safety.

---

## Key Insights

### 1. RAG hurts MCQ accuracy for all on-device models

Every local model sees **degraded MCQ performance** when RAG context is injected. The average MCQ drop ranges from -2.2pp (Gemma E4B) to -6.0pp (Meditron3). RAG adds ~3,000 characters of context, which appears to distract smaller models from the core question. GPT-5 is the only model that maintains performance with RAG (80.9% avg in both conditions).

| Model | Baseline MCQ Avg | +RAG MCQ Avg | Delta |
|---|:---:|:---:|:---:|
| GPT-5 | 80.9% | 80.9% | 0.0 |
| Gemma E4B | 45.6% | 43.4% | -2.2 |
| MedGemma 4B | 44.5% | 39.4% | -5.1 |
| Meditron3 8B | 41.0% | 35.0% | -6.0 |
| Gemma E2B | 41.4% | 37.2% | -4.2 |

### 2. RAG has minimal impact on open-ended quality

On open-ended benchmarks, RAG effects are small and mixed. Gemma E4B+RAG shows a slight improvement (+0.02 avg), while other models see small declines. The retrieved OBGYN guidelines don't consistently improve answer quality on these benchmarks — possibly because the questions don't always match the chunk corpus.

### 3. The "fluency trap" — high clarity masks low accuracy

Across all models, **clarity scores ~4.0/5** even when accuracy is low. For Gemma E4B, when accuracy is 1-2 (n=128 responses), clarity remains **3.98/5**. The models write convincingly even when factually wrong — a dangerous property for medical applications where users may trust well-articulated but incorrect advice.

### 4. Gemma E4B is the best on-device model

Gemma E4B achieves the highest average scores among local models in both MCQ (45.6%) and open-ended (3.06/5). It also degrades the least with RAG (-2.2pp MCQ), making it the most robust choice for the on-device RAG pipeline.

**On-device model ranking** (by average across all benchmarks):
1. **Gemma 3n E4B** — best overall
2. **MedGemma 4B** — competitive on MCQ, slightly lower on open-ended
3. **Meditron3 8B** — despite being 2x larger, doesn't outperform E4B
4. **Gemma 3n E2B** — smallest, reasonable performance for its size

### 5. GPT-5 open-ended generation failed

GPT-5 dominates MCQ (80.9% avg) but its open-ended scores are invalid. Investigation of the raw results reveals that **GPT-5 returned empty responses** (0 characters) for all 284 Kenya Vignettes and most other open-ended questions. The judge correctly scored empty responses as 1/5 across all dimensions. This is a **pipeline bug** (likely a prompt format or API parameter issue for open-ended generation), not a judge calibration problem. GPT-5's open-ended scores should be disregarded entirely; a re-evaluation with the generation bug fixed is needed.

### 6. Medical finetuning provides limited benefit at this scale

MedGemma 4B and Meditron3 8B, despite medical-domain finetuning, do not consistently outperform the general-purpose Gemma E4B. MedGemma edges ahead on MedQA USMLE (44.8% vs 44.1%) but trails on AfriMedQA (37.6% vs 40.8%) and open-ended tasks. Meditron3 at 8B parameters only matches or underperforms the 4B Gemma E4B. This suggests that at Q4_0 quantization levels, general instruction-following capability matters more than domain-specific pretraining.

### 7. AfriMedQA is the hardest benchmark

All models score lowest on AfriMedQA MCQ (28-65%), reflecting its focus on African clinical contexts that may be underrepresented in training data. This is particularly relevant for the MAM-AI app's target deployment in Zanzibar.

---

## Recommendations

1. **Keep Gemma 3n E4B as the on-device model** — it offers the best balance of accuracy, quality, and RAG robustness among all tested local models.

2. **Reconsider RAG for MCQ-style queries** — the current retrieval pipeline degrades factual accuracy for local models. Options: (a) improve chunk relevance filtering, (b) increase similarity threshold to avoid injecting irrelevant context, (c) only inject context when similarity is high.

3. **Re-run GPT-5 open-ended evaluation** — the generation pipeline produced empty responses. Fix the API call parameters and re-evaluate to get a valid cloud baseline for open-ended tasks.

4. **Address the fluency trap** — consider adding confidence disclaimers or uncertainty signals, since the model's high clarity masks low accuracy and can mislead users.

5. **The E2B model is viable for constrained devices** — at 2.8 GB (vs 4.1 GB for E4B), it retains ~90% of E4B's performance, making it a reasonable fallback for lower-end hardware.
