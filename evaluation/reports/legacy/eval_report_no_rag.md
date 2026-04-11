# MAM-AI Model Evaluation Report (No-RAG)

## Setup

**Models evaluated**:
- **Gemma 4 E4B-IT** (Q4_0 GGUF) — current deployed model
- **Gemma 3n E4B-IT** (4.1 GB, Q4_0 GGUF) — previously deployed in the MAM-AI app
- **Gemma 3n E2B-IT** (2.8 GB, Q4_0 GGUF) — smaller variant
- **MedGemma 4B-IT** (2.3 GB, Q4_0 GGUF) — medical-domain finetuned
- **Meditron3 8B** (4.7 GB, Q4_0 GGUF) — medical-domain finetuned (Llama 3.1 base)
- **GPT-5** (OpenAI API) — cloud baseline

On-device models run via llama-cpp-python with CUDA on an NVIDIA A100. GPT-5 via OpenAI API. All results are **without RAG** (no retrieved context injected into prompts).

**Benchmarks** (6 datasets):
- *MCQ* (accuracy): AfriMedQA MCQ (660), MedQA USMLE (1,025), MedMCQA (500)
- *Open-ended* (LLM-as-judge, 1–5): Kenya Vignettes (284), AfriMedQA SAQ (37), WHB Stumps (20)

**Judge**: GPT-5.2 scoring on 5 weighted dimensions — accuracy (30%), safety (25%), completeness (20%), helpfulness (15%), clarity (10%).

---

## Results

### MCQ Benchmarks (accuracy %)

| Model | AfriMedQA | MedQA USMLE | MedMCQA | Avg |
|---|:---:|:---:|:---:|:---:|
| GPT-5 | **65.2** | **91.3** | **86.2** | **80.9** |
| Gemma E4B | 40.8 | 44.1 | 51.8 | 45.6 |
| MedGemma 4B | 37.6 | 44.8 | 51.0 | 44.5 |
| Gemma 4 E4B | 37.0 | 40.8 | 51.0 | 42.9 |
| Gemma E2B | 37.4 | 39.8 | 47.0 | 41.4 |
| Meditron3 8B | 31.4 | 41.1 | 50.6 | 41.0 |

### Open-ended Benchmarks (weighted judge score /5)

| Model | Kenya Vignettes | AfriMedQA SAQ | WHB Stumps | Avg |
|---|:---:|:---:|:---:|:---:|
| GPT-5† | **4.69** | **4.78** | **3.93** | **4.47** |
| Gemma E4B | 3.11 | 3.39 | 2.68 | 3.06 |
| Gemma 4 E4B | 3.11 | 2.97 | 2.75 | 2.94 |
| MedGemma 4B | 2.93 | 3.22 | 2.54 | 2.90 |
| Meditron3 8B | 2.76 | 3.34 | 2.55 | 2.88 |
| Gemma E2B | 2.75 | 2.95 | 2.58 | 2.76 |

*†GPT-5 Kenya Vignettes: partial (31/284 questions, API quota exhausted). SAQ and WHB Stumps are complete.*

### Per-Dimension Breakdown (open-ended)

Each response is scored 1–5 on five dimensions. Weighted = accuracy (30%) + safety (25%) + completeness (20%) + helpfulness (15%) + clarity (10%).

#### Kenya Vignettes (n=284; GPT-5 n=31†)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5† | **4.41** | **4.66** | **4.79** | **5.00** | **4.97** | **4.69** |
| Gemma 4 E4B | 2.87 | 2.96 | 2.87 | 3.58 | 3.97 | 3.11 |
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
| Gemma 4 E4B | 2.65 | 3.08 | 2.59 | 3.35 | 3.84 | 2.97 |
| Gemma E2B | 2.41 | 2.86 | 3.08 | 3.32 | 3.97 | 2.95 |

#### WHB Stumps (n=20)

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5 | **3.45** | **3.85** | **3.85** | **4.65** | **4.65** | **3.93** |
| Gemma 4 E4B | 2.40 | 2.75 | 2.30 | 3.35 | 3.80 | 2.75 |
| Gemma E4B | 2.25 | 2.50 | 2.30 | 3.45 | 4.00 | 2.68 |
| Gemma E2B | 2.05 | 2.40 | 2.35 | 3.30 | 3.95 | 2.58 |
| Meditron3 8B | 2.30 | 2.40 | 2.05 | 3.00 | 4.00 | 2.55 |
| MedGemma 4B | 2.15 | 2.25 | 2.30 | 3.15 | 4.00 | 2.54 |

### Cross-Model Dimension Averages

Averaged across all three open-ended benchmarks:

| Model | Accuracy | Safety | Completeness | Helpfulness | Clarity | Weighted |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| GPT-5† | **4.22** | **4.38** | **4.45** | **4.86** | **4.87** | **4.47** |
| Gemma E4B | 2.60 | 2.88 | 3.03 | 3.66 | 4.03 | 3.06 |
| Gemma 4 E4B | 2.64 | 2.93 | 2.59 | 3.43 | 3.87 | 2.94 |
| MedGemma 4B | 2.45 | 2.64 | 2.96 | 3.39 | 4.00 | 2.90 |
| Meditron3 8B | 2.73 | 2.74 | 2.43 | 3.26 | 4.05 | 2.88 |
| Gemma E2B | 2.28 | 2.52 | 2.79 | 3.28 | 3.96 | 2.76 |

GPT-5 scores ~4.5/5 across all dimensions — a large gap over on-device models (~3.0/5). Among on-device models: **Clarity (~4.0) > Helpfulness (~3.3) > Completeness (~2.8) > Safety (~2.7) > Accuracy (~2.5)**. All on-device models produce well-structured responses but struggle with factual accuracy and clinical safety.

---

## Key Insights

### 1. The "fluency trap" — high clarity masks low accuracy

For on-device models, **clarity scores ~4.0/5** even when accuracy is 1–2/5. The models write convincingly when factually wrong — dangerous for medical applications where users may trust well-articulated but incorrect advice. GPT-5 does not exhibit this: its clarity (~4.9) is backed by high accuracy (~4.2).

### 2. Gemma 4 E4B trails Gemma 3n E4B on current quality evidence

Gemma 4 E4B scores **42.9% average MCQ accuracy** and **2.94/5 average open-ended weighted score**. Both trail Gemma 3n E4B, which reaches **45.6% MCQ** and **3.06/5 open-ended**. Gemma 4 matches Gemma 3n E4B on Kenya Vignettes (3.11), beats it slightly on WHB Stumps (2.75 vs 2.68), but drops materially on AfriMedQA SAQ (2.97 vs 3.39) and on two of the three MCQ benchmarks.

**Gemma 3n E4B remains the strongest on-device model overall** on the current benchmark set.

### 3. GPT-5 is the quality ceiling

GPT-5 scores 4.47/5 on open-ended vs 3.06/5 for Gemma E4B — a **1.4-point gap**. On MCQ: 80.9% vs 45.6%. This quantifies the accuracy cost of on-device inference. The gap is largest on accuracy (4.22 vs 2.60) and smallest on clarity (4.87 vs 4.03).

*Note: An initial GPT-5 run produced empty open-ended responses due to a `max_completion_tokens` budget issue with reasoning tokens. Fixed by removing the token cap. Kenya Vignettes results are partial (31/284) due to API quota exhaustion.*

### 4. Medical finetuning provides limited benefit at this scale

MedGemma and Meditron3, despite medical-domain finetuning, do not consistently outperform general-purpose Gemma E4B. Meditron3 at 8B parameters underperforms the 4B E4B. At Q4_0 quantization, instruction-following capability matters more than domain-specific pretraining.

### 5. AfriMedQA is the hardest benchmark

All models score lowest on AfriMedQA MCQ (31–65%), reflecting African clinical contexts underrepresented in training data — particularly relevant for MAM-AI's deployment in Zanzibar.

---

## Recommendations

1. **Do not justify the model switch on current benchmark evidence.** Gemma 4 E4B is worse than Gemma 3n E4B on both MCQ (**42.9% vs 45.6%**) and open-ended quality (**2.94/5 vs 3.06/5**).

2. **Keep Gemma 3n E4B as the quality baseline** unless Gemma 4 E4B shows a clear advantage in future evaluation or there is another product reason to prefer it despite the CPU TTFT regression.

3. **Address the fluency trap** — on-device models score ~4.0 clarity with ~2.5 accuracy. Consider adding uncertainty signals so users don't over-trust well-written but inaccurate responses.

4. **E2B is viable for constrained devices** — at 2.8 GB (vs 4.1 GB), it retains ~90% of E4B's performance.

5. **Complete GPT-5 Kenya Vignettes** — only 31/284 questions evaluated. Top up API credits and re-run; `--run-dir` auto-resume will continue from the checkpoint.
