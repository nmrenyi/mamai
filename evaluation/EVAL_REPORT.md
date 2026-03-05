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

**Judge**: GPT-5.2 scoring on 5 dimensions (accuracy, completeness, safety, clarity, relevance).

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

### Open-ended Benchmarks (judge score /5)

| Model | Kenya Vignettes | AfriMedQA SAQ | WHB Stumps | Avg |
|---|:---:|:---:|:---:|:---:|
| GPT-5 | 1.01 | 1.63 | 1.48 | 1.37 |
| GPT-5 + RAG | 1.01 | **2.23** | 1.22 | 1.49 |
| Gemma E4B | **3.11** | 3.39 | **2.68** | **3.06** |
| Gemma E4B + RAG | 3.08 | **3.48** | 2.67 | **3.08** |
| MedGemma 4B | 2.93 | 3.22 | 2.54 | 2.90 |
| MedGemma + RAG | 2.93 | 3.09 | **2.77** | 2.93 |
| Meditron3 8B | 2.76 | **3.34** | 2.55 | 2.88 |
| Meditron3 + RAG | 2.68 | 3.11 | 2.32 | 2.70 |
| Gemma E2B | 2.75 | 2.95 | 2.58 | 2.76 |
| Gemma E2B + RAG | 2.73 | 2.91 | 2.39 | 2.68 |

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

### 3. Gemma E4B is the best on-device model

Gemma E4B achieves the highest average scores among local models in both MCQ (45.6%) and open-ended (3.06/5). It also degrades the least with RAG (-2.2pp MCQ), making it the most robust choice for the on-device RAG pipeline.

**On-device model ranking** (by average across all benchmarks):
1. **Gemma 3n E4B** — best overall
2. **MedGemma 4B** — competitive on MCQ, slightly lower on open-ended
3. **Meditron3 8B** — despite being 2x larger, doesn't outperform E4B
4. **Gemma 3n E2B** — smallest, reasonable performance for its size

### 4. Medical finetuning provides limited benefit at this scale

MedGemma 4B and Meditron3 8B, despite medical-domain finetuning, do not consistently outperform the general-purpose Gemma E4B. MedGemma edges ahead on MedQA USMLE (44.8% vs 44.1%) but trails on AfriMedQA (37.6% vs 40.8%) and open-ended tasks. Meditron3 at 8B parameters only matches or underperforms the 4B Gemma E4B. This suggests that at Q4_0 quantization levels, general instruction-following capability matters more than domain-specific pretraining.

### 5. GPT-5 open-ended scores require investigation

GPT-5 dominates MCQ (80.9% avg) but scores anomalously low on open-ended tasks (1.37/5 avg vs 3.06/5 for Gemma E4B). This is likely a **judge calibration artifact**: GPT-5 produces longer, more structured responses that may be penalized by the rubric, or the judge (also GPT-based) may apply harsher standards to responses it recognizes as AI-generated. The open-ended scores for GPT-5 should not be taken at face value.

### 6. AfriMedQA is the hardest benchmark

All models score lowest on AfriMedQA MCQ (28-65%), reflecting its focus on African clinical contexts that may be underrepresented in training data. This is particularly relevant for the MAM-AI app's target deployment in Zanzibar.

---

## Recommendations

1. **Keep Gemma 3n E4B as the on-device model** — it offers the best balance of accuracy, quality, and RAG robustness among all tested local models.

2. **Reconsider RAG for MCQ-style queries** — the current retrieval pipeline degrades factual accuracy for local models. Options: (a) improve chunk relevance filtering, (b) increase similarity threshold to avoid injecting irrelevant context, (c) only inject context when similarity is high.

3. **Investigate GPT-5 judge scoring** — the low open-ended scores for GPT-5 suggest the evaluation rubric or judge model needs calibration. Consider using human evaluation as ground truth for a subset.

4. **The E2B model is viable for constrained devices** — at 2.8 GB (vs 4.1 GB for E4B), it retains ~90% of E4B's performance, making it a reasonable fallback for lower-end hardware.
