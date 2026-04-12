# MAM-AI On-Device LLM Benchmark Report

**Date:** 4 April 2026  
**Device:** OPPO OPD2413 (Snapdragon 8 Elite SM8750P, 16 GB RAM, Android 15)  
**Benchmark:** 18 clinical queries (8 short / 6 medium / 4 long), 1 run each, retrieval disabled, 5 warmup queries before timed runs

---

## Configurations Tested

| # | Config | Framework | Model | Backend |
|---|---|---|---|---|
| 1 | Baseline | MediaPipe 0.10.25 | Gemma 3n E4B IT int4 | CPU |
| 2 | Framework migration | LiteRT-LM 0.10.0 | Gemma 3n E4B IT int4 | CPU |
| 3 | Model upgrade | LiteRT-LM 0.10.0 | Gemma 4 E4B IT | CPU |

---

## Results

### Average latency by query length

| Config | Short (8) | Medium (6) | Long (4) | **Overall (18)** |
|---|---|---|---|---|
| **MediaPipe + Gemma 3n** | | | | |
| — TTFT | 6,219 ms | 8,669 ms | 16,621 ms | **9,347 ms** |
| — Decode | 13,437 ms | 19,245 ms | 22,272 ms | **17,336 ms** |
| — Total | 19,656 ms | 27,914 ms | 38,893 ms | **26,683 ms** |
| — tok/s | 12.9 | 11.4 | 12.1 | **12.2** |
| **LiteRT-LM + Gemma 3n** | | | | |
| — TTFT | 6,086 ms | 6,292 ms | 9,176 ms | **6,841 ms** |
| — Decode | 15,217 ms | 17,559 ms | 23,870 ms | **17,920 ms** |
| — Total | 21,303 ms | 23,852 ms | 33,046 ms | **24,762 ms** |
| — tok/s | 12.5 | 13.0 | 13.4 | **12.9** |
| **LiteRT-LM + Gemma 4 E4B** | | | | |
| — TTFT | 11,660 ms | 11,705 ms | 11,630 ms | **11,668 ms** |
| — Decode | 12,639 ms | 16,763 ms | 17,590 ms | **15,114 ms** |
| — Total | 24,299 ms | 28,469 ms | 29,220 ms | **26,783 ms** |
| — tok/s | 13.4 | 13.8 | 14.4 | **13.8** |

### Change vs baseline (MediaPipe + Gemma 3n)

| Config | TTFT | Decode | Total | tok/s |
|---|---|---|---|---|
| LiteRT-LM + Gemma 3n | **−27%** | +3% | **−7%** | +6% |
| LiteRT-LM + Gemma 4 E4B | +25% | **−13%** | ~0% | **+13%** |

---

## Key Findings

**1. LiteRT-LM cuts TTFT by 27% on the same model.**  
Switching from MediaPipe to LiteRT-LM (Gemma 3n, no model change) reduces average TTFT from 9.3 s to 6.8 s. The benefit grows with query length: long queries improve from 16.6 s to 9.2 s TTFT (−45%).

**2. Gemma 4 has a fixed TTFT independent of query length.**  
All 18 queries — short, medium, and long — produced a TTFT of 11.6–11.8 s. This suggests the model has a constant prefill overhead on this hardware, likely dominated by the system prompt (~200 tokens). The extra tokens in long queries add no measurable prefill cost. This is in sharp contrast to Gemma 3n where TTFT scales with input length.

**3. Gemma 4 decodes 13% faster than the MediaPipe baseline.**  
Average decode throughput: 13.8 tok/s (Gemma 4) vs 12.2 tok/s (MediaPipe baseline). The advantage grows with response length — long queries reach 14.4 tok/s.

**4. Gemma 4's total response time is similar to the MediaPipe baseline.**  
The TTFT regression (+25%) and decode improvement (−13%) largely cancel out. For short queries (most common in practice) total time is 24.3 s vs 19.7 s — about 4 seconds slower.

**5. LLM model load time is fast and similar across all configurations.**  
Load times: 595 ms (MediaPipe), 646 ms (LiteRT-LM Gemma 3n), 758 ms (LiteRT-LM Gemma 4). All under 1 second. Warmup cost (5 queries) is 95–137 seconds and is paid once per app session.

---

## Recommendation

For the current CPU-only deployment, **LiteRT-LM + Gemma 3n** offers the best user experience: TTFT is 27% faster than the baseline while total time improves 7%. Gemma 4 E4B is a more capable model but its higher fixed TTFT on CPU makes it feel slower to the user despite faster decode.

**The situation reverses on GPU.** Prefill is massively parallelisable — on a Snapdragon 8 Elite Adreno 830, GPU prefill rates are typically 10–40× faster than CPU. Gemma 4's constant TTFT (dominated by a fixed model overhead) would drop sharply, and its faster decode would give it a clear advantage overall.

GPU support requires LiteRT-LM 0.10.1, which is not yet published to Google Maven (tracked: [google-ai-edge/LiteRT-LM#1856](https://github.com/google-ai-edge/LiteRT-LM/issues/1856)). The GPU branch (`feat/gpu-backend`) is ready — it requires a one-line change once 0.10.1 is available.
