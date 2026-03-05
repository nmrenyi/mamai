# MAM-AI On-Device Latency Report

**Device**: Google Pixel 7 (Tensor G2, 8 GB RAM, Android 16)
**Dates**: 2026-02-26 (backend comparison), 2026-03-04/05 (automated benchmarks)
**Build**: Release APK, CPU backend

## Executive Summary

We evaluated four model/backend combinations and two Gemma 3n model sizes for on-device medical search latency on the Pixel 7. Key results:

- **Best stack**: Gemma 3n E4B on MediaPipe — fastest across all metrics
- **Typical query latency**: 1.0–1.5 min (No RAG), 1.2–1.8 min (with RAG) using E4B
- **E2B is not a viable alternative**: despite being smaller, E2B is 2–3x slower for medium/long queries
- **llama.cpp is not competitive**: 2.8x slower than MediaPipe for the same model

---

## Part 1: Backend Comparison (llama.cpp vs MediaPipe)

*Single-query manual tests, 2026-02-26. Short query, no RAG.*

| | MedGemma 4B (llama.cpp) | Gemma 3n E4B (llama.cpp) | Gemma 3n E4B (MediaPipe) |
|---|---|---|---|
| **Model size** | 2.2 GB | 4.1 GB | 4.1 GB |
| **Quantization** | Q4_0 (GGUF) | Q4_0 (GGUF) | int4 (.task) |
| **Model load** | 3.4s | 13.5s | 1.2s |
| **Prefill / TTFT** | 45.3s | 62.7s | 16.4s |
| **Decode** | 3.8s (4.7 t/s) | 40.0s (3.5 t/s) | 19.8s (~5.2 t/s) |
| **Total query** | 49.2s | 102.7s | **36.2s** |

**Conclusion**: MediaPipe is 2.8x faster than llama.cpp for Gemma 3n. MediaPipe's prefill is 3–4x faster due to Google's Tensor G2-specific optimizations. llama.cpp's only advantage is model flexibility (any GGUF model) and smaller APK size (58 MB vs 164 MB).

---

## Part 2: Automated Benchmark — Gemma 3n E4B (Production Model)

*108 runs: 18 queries x 2 modes x 3 repeats. 10s cooldown. 2026-03-04.*

### Initialization

| Metric | Time |
|---|---|
| Gecko + SQLite init | 179ms |
| LLM model load | 35.0s |
| Total initialization | 35.1s |

### Latency by Category (Median)

| Category | Mode | TTFT | Decode | Total | TPS |
|---|---|---|---|---|---|
| Short (3–7 words) | No RAG | 17.9s | 53.9s | **72s** | 3.3 |
| Short | RAG | 35.2s | 50.8s | **94s** | 3.3 |
| Medium (20–30 words) | No RAG | 17.6s | 59.2s | **79s** | 3.2 |
| Medium | RAG | 35.0s | 48.0s | **91s** | 3.2 |
| Long (65–80 words) | No RAG | 36.4s | 72.3s | **109s** | 3.5 |
| Long | RAG | 36.4s | 59.0s | **103s** | 3.4 |

### RAG Overhead

| Metric | No RAG | RAG | Overhead |
|---|---|---|---|
| Retrieval time | — | 8.4s (median) | +8.4s |
| TTFT | 27.7s | 46.3s | +67% |
| Decode time | 67.8s | 62.0s | -9% |
| Total query time | 95.6s | 117.3s | +23% |
| Response length | 826 chars | 668 chars | **-19%** |

RAG adds ~8–10s for retrieval (Gecko embedding + SQLite cosine search) and increases TTFT due to longer prompt prefill. However, RAG responses are 19% shorter and more focused — grounding documents help the model stay concise.

### Decode Throughput

Stable at **3.2–3.5 tok/s** across categories. This is the hardware-limited decode speed of Gemma 3n E4B int4 on the Tensor G2 CPU.

### Outliers

Three query-mode combinations consistently produce 4x slowdowns (0.75–0.96 tok/s):

| Query | Mode | Median Total | TPS |
|---|---|---|---|
| "When to cut the umbilical cord" | No RAG | 255s | 0.85 |
| "Breastfeeding positions for new mothers" | RAG | 379s | 0.92 |
| Preeclampsia emergency | RAG | 406s | 0.75 |

These are query-content-specific (not thermal) — reproducible across all 3 repeats at different points in the run. Excluding these outliers, the remaining 102 runs show tight consistency at ~90s median.

### Thermal & Memory

- **Thermal throttling**: +1% drift over 3.5 hours — negligible with 10s cooldown
- **Peak heap**: 16 MB (well within 256 MB max; LLM itself is memory-mapped)

---

## Part 3: Automated Benchmark — Gemma 3n E2B (Smaller Model)

*108 runs: 18 queries x 2 modes x 3 repeats. 10s cooldown. 2026-03-05.*

### Initialization

| Metric | E4B | E2B | Diff |
|---|---|---|---|
| Model file size | 4.1 GB | 2.9 GB | -29% |
| LLM model load | 35.0s | **1.1s** | **-97%** |
| Total initialization | 35.1s | 15.8s | -55% |

### Latency by Category (Median)

| Category | Mode | TTFT | Decode | Total | TPS |
|---|---|---|---|---|---|
| Short | No RAG | 13.2s | 40.9s | **54s** | 5.1 |
| Short | RAG | 25.6s | 35.9s | **71s** | 5.0 |
| Medium | No RAG | 76.5s | 155.9s | **234s** | 1.4 |
| Medium | RAG | 161.8s | 100.4s | **293s** | 1.3 |
| Long | No RAG | 163.1s | 167.1s | **326s** | 1.3 |
| Long | RAG | 167.1s | 163.6s | **369s** | 1.3 |

### Thermal Behavior

The auto-generated thermal analysis reports +277% degradation from first-third to last-third of the run. However, this reflects the **query ordering** (short queries first, long queries last) rather than true thermal throttling — E2B is inherently 5–6x slower on long queries.

---

## Part 4: E4B vs E2B Head-to-Head

### Median Total Query Time

| Category | Mode | E4B | E2B | Diff |
|---|---|---|---|---|
| Short | No RAG | 72s | **54s** | **-25%** |
| Short | RAG | 94s | **71s** | **-25%** |
| Medium | No RAG | **79s** | 234s | +194% |
| Medium | RAG | **91s** | 293s | +223% |
| Long | No RAG | **109s** | 326s | +198% |
| Long | RAG | **103s** | 369s | +260% |

### Decode Throughput

| Category | E4B (tok/s) | E2B (tok/s) | Diff |
|---|---|---|---|
| Short | 3.3 | **5.0–5.1** | **+52–56%** |
| Medium | **3.2** | 1.3–1.4 | -58% |
| Long | **3.4–3.5** | 1.3 | -61–62% |

### TTFT (Time To First Token)

| Category | Mode | E4B | E2B | Diff |
|---|---|---|---|---|
| Short | No RAG | 17.9s | **13.2s** | -26% |
| Short | RAG | 35.2s | **25.6s** | -27% |
| Medium | No RAG | **17.6s** | 76.5s | +335% |
| Medium | RAG | **35.0s** | 161.8s | +362% |
| Long | No RAG | **36.4s** | 163.1s | +348% |
| Long | RAG | **36.4s** | 167.1s | +359% |

### Overall (all 108 runs, median)

| Metric | E4B | E2B | Diff |
|---|---|---|---|
| Total query time | **91s** | 205s | +125% |
| TTFT | **35s** | 71s | +105% |
| Decode time | **58s** | 99s | +72% |
| Decode throughput | 3.3 tok/s | 1.4 tok/s | -57% |
| Benchmark duration | 3.5 hr | **6.1 hr** | +73% |

### Analysis

E2B's counterintuitive behavior — faster for short queries but dramatically slower for medium/long — likely stems from:

- **Prefill bottleneck**: E2B's TTFT explodes 3.5–4.6x for medium/long queries, suggesting the smaller model's prefill computation scales poorly with input length on this hardware
- **KV cache efficiency**: E4B's larger hidden dimensions may produce more compute-efficient attention patterns on the Tensor G2
- **MediaPipe kernel optimization**: The int4 decode kernels may be better optimized for E4B's tensor shapes

---

## Recommendation

**Use Gemma 3n E4B on MediaPipe** for production. It delivers:

- Consistent 3.2–3.5 tok/s decode regardless of query length
- Stable TTFT scaling (18–36s vs E2B's 13–167s)
- Predictable 1–2 minute total query times

E2B is only preferable if the app needs sub-2s cold start and handles exclusively short queries without RAG — neither applies to MAM-AI, where RAG context injection makes every query effectively a medium/long input.

Do **not** use llama.cpp — it is 2.8x slower than MediaPipe for the same model.

## Methodology

### Manual Tests (Part 1)

Single-query tests with force-stopped app, CPU fully recovered (2850 MHz), retrieval disabled. Timing from `adb logcat -s mam-ai`.

### Automated Benchmarks (Parts 2–4)

- 18 medical queries across 3 categories: short (8, 3–7 words), medium (6, 20–30 words), long (4, 65–80 words)
- Each run through `RagPipeline.generateResponse()` from standalone `BenchmarkActivity` (no Flutter overhead)
- Separate Android process (`:benchmark`) isolated from the main app
- Warmup query before timed runs (JIT, CPU cache, memory allocation)
- 10s cooldown between queries to mitigate thermal throttling
- TTFT = time from generation start to first non-empty token callback
- Decode time = first token to generation complete
- Token count estimated at ~4 chars/token (Gemma tokenizer average)
- Retrieval = Gecko embedding + SQLite cosine similarity (top 3 docs)
- Generation params: temperature=1, top_p=0.95, top_k=64, single-turn only

---

*E4B benchmark: 108 runs, 0 errors, 3.5 hours. E2B benchmark: 108 runs, 0 errors, 6.1 hours. Device: Google Pixel 7.*
