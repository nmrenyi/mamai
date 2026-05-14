# MAM-AI On-Device Latency Sweep — GPU vs CPU

_Generated: 2026-05-15T07:56:55_


## Device & stack

- **Device**: OnePlus OPD2413 (SM8750P) — Android 15
- **Model**: Gemma 4 E4B (`gemma-4-E4B-it.litertlm`)
- **LiteRT-LM**: 0.11.0
- **Backends tested**: GPU (OpenCL, via `useGpuForLlm=true`) and CPU
- **Sampling**: temp=1.0, top_p=0.95, top_k=64, max_tokens=32000

## Methodology

Per backend × k configuration: 18 queries × 1 mode (RAG-only) × 3 repeats = 54 timed runs. 
Plus a No-RAG baseline per backend (k=0 via `--no-retrieval`). 10-second cooldown between runs 
for thermal stability. Activity → ForegroundService with PARTIAL_WAKE_LOCK so the run survives 
screen-off and device-lock; OPPO Hans whitelist set manually.

- `TTFT` excludes retrieval — measured from end-of-retrieval to first generated token.
- `decode` is first-token to last-token.
- `total_query` is everything: `retrieval + TTFT + decode`.
- Reported as median across the 54 runs unless noted (p95 in tables marked `p95`).

## Headline — Median total query latency (seconds)

| k | doc_chars med | GPU short / med / long | CPU short / med / long | CPU÷GPU |
|---:|---:|---:|---:|---:|
| **0 (no-RAG)** | 0 | 12.9 / 15.6 / 16.1 | 27.2 / 26.9 / 29.8 | 1.94× |
| 1 | 561 | 13.1 / 12.6 / 17.3 | 29.3 / 31.9 / 30.3 | 2.14× |
| 3 | 2098 | 18.6 / 18.6 / 21.0 | 37.3 / 44.5 / 42.5 | 2.24× |
| 5 | 3547 | 18.2 / 20.0 / 21.4 | 54.8 / 60.7 / 63.0 | 3.07× |
| 7 | 5139 | 21.3 / 23.2 / 22.8 | 61.4 / 62.3 / 60.4 | 2.72× |
| 10 | 7482 | 22.5 / 20.5 / 20.4 | 61.8 / 70.6 / 77.9 | 3.10× |
| 15 | 11297 | 25.3 / 24.0 / 22.4 | 84.8 / 80.8 / 89.7 | 3.48× |
| 20 | 14520 | 23.9 / 20.5 / 18.5 | 88.7 / 95.6 / 95.6 | 4.46× |

## TTFT (ms, median) — prefill cost grows with retrieved-doc content

| k | doc_chars med | GPU TTFT | CPU TTFT | CPU÷GPU |
|---:|---:|---:|---:|---:|
| **0 (no-RAG)** | 0 | 962 | 12633 | 13.1× |
| 1 | 561 | 954 | 12649 | 13.3× |
| 3 | 2098 | 989 | 18356 | 18.6× |
| 5 | 3547 | 1884 | 36424 | 19.3× |
| 7 | 5139 | 1920 | 36444 | 19.0× |
| 10 | 7482 | 2523 | 40013 | 15.9× |
| 15 | 11297 | 3457 | 54748 | 15.8× |
| 20 | 14520 | 3986 | 72881 | 18.3× |

## Decode (ms, median) — first token to last token

Decode time mostly tracks output length, not k or doc content. Variation across k reflects 
the model writing *longer answers* when given more context (more material to draw on).

| k | GPU decode | CPU decode | CPU÷GPU |
|---:|---:|---:|---:|
| **0 (no-RAG)** | 13470 | 15345 | 1.14× |
| 1 | 11415 | 13961 | 1.22× |
| 3 | 16364 | 19110 | 1.17× |
| 5 | 15929 | 21645 | 1.36× |
| 7 | 17215 | 23473 | 1.36× |
| 10 | 18118 | 21699 | 1.20× |
| 15 | 16820 | 22497 | 1.34× |
| 20 | 14688 | 22634 | 1.54× |

## p95 total query latency (s) — tail-latency view

| k | GPU p95 | CPU p95 |
|---:|---:|---:|
| **0 (no-RAG)** | 26.1 | 38.4 |
| 1 | 26.1 | 37.1 |
| 3 | 30.2 | 64.3 |
| 5 | 30.7 | 74.6 |
| 7 | 35.1 | 81.7 |
| 10 | 29.0 | 84.5 |
| 15 | 30.6 | 112.6 |
| 20 | 35.3 | 104.9 |

## Errors and the 4096-token context wall

| k | GPU errors / 54 | CPU errors / 54 |
|---:|---:|---:|
| **0 (no-RAG)** | 0 | 0 |
| 1 | 0 | 0 |
| 3 | 0 | 0 |
| 5 | 0 | 0 |
| 7 | 0 | 0 |
| 10 | 0 | 0 |
| 15 | 0 | 0 |
| 20 | 24 | 24 |

At k=20, **24 of 54 runs failed on both GPU and CPU** with `Input token ids are too long. 
Exceeding the maximum number of tokens allowed: …>= 4096`. The **exact same 8 queries failed on both 
backends** (`long_01, long_03, medium_02, medium_04, short_01, short_03, short_04, short_05`) — 
the same 24 (query × rep) pairs. This is direct evidence that the 4096-token cap is a property of 
the Gemma 4 E4B `.litertlm` artifact itself, not a runtime configuration, not a backend choice. 
The 8 surviving queries on either side were the ones whose retrieved chunks happened to be shorter.

Successful-run timing at CPU k=20: TTFT 65–73 s, total 89–96 s — confirming CPU is well past any 
deployment budget at this depth even when the request fits in the context window.

## Wall-clock comparison

| k | GPU wall (min) | CPU wall (min) | CPU÷GPU |
|---:|---:|---:|---:|
| **0 (no-RAG)** | 23.5 | 36.9 | 1.57× |
| 1 | 23.0 | 38.7 | 1.68× |
| 3 | 27.3 | 50.2 | 1.84× |
| 5 | 28.2 | 63.0 | 2.23× |
| 7 | 30.0 | 66.5 | 2.22× |
| 10 | 29.1 | 73.2 | 2.51× |
| 15 | 32.4 | 90.8 | 2.80× |
| 20 | 22.8 | 58.6 | 2.57× |

## Key findings


### 1. GPU is the practical choice for this workload on Snapdragon 8 Elite
GPU TTFT runs around **1–3.5 s** across k=0–15. CPU TTFT runs around **12.6 s (no-RAG) → 55 s (k=15)**. 
That's a 13–19× TTFT speedup from GPU. Decode time is largely backend-invariant (memory-bandwidth-bound), 
so the *total* speedup is closer to 2–3.5× — but those seconds of TTFT translate directly to perceived UX latency.

### 2. The model's 4096-token context window is the binding ceiling at high k
k=15 works cleanly (54/54 on both GPU and CPU). k=20 fails identically on **both backends** — 
the **exact same 24 of 54 runs (8 queries × 3 reps)** error with `Input token ids are too long … >= 4096`. 
Same queries fail on both because the chunks retrieved are deterministic and chunk length × k drives 
the prompt past the window. The 4096-token cap is a property of the `.litertlm` model artifact, 
not a runtime config and not a backend choice. **k_max ≈ 17–18** for this artifact. 
Latency is *not* the constraint at the upper end; the model's context window is.

### 3. Latency is not the binding factor on GPU below k=15
GPU total medians stay between 13 s (no-RAG) and 25 s (k=15) — all well under any reasonable UX budget. 
Picking k* should be driven by **answer quality** (do more chunks help or hurt the small generator?), 
not by what fits in the latency budget.

### 4. CPU at k≥5 hits any reasonable UX budget; at k=15 it's prohibitively slow
CPU totals: k=3 → 37–44 s, k=5 → 55–63 s, k=7 → 60–62 s, k=10 → 62–78 s, k=15 → 81–90 s. 
p95 at CPU k=15 hits **113 s** — almost two minutes for the slowest 5% of queries. If GPU isn't 
available (lower-tier devices), the practical CPU operating point is **k ≤ 3** for a sub-60s budget, 
or **k ≤ 1** if you want sub-40s p95.

### 5. Decode time is content-driven, not k-driven
Decode time tracks output length. As k grows, the model writes *longer* responses — likely because 
more context = more material to weave in. This is a quality-coupled latency effect, not a prefill effect. 
Decode-time difference between GPU and CPU is only ~1.1–1.4× across all k, since decode is memory-bandwidth-bound, 
not compute-bound on this hardware.

### 6. TTFT scales linearly with retrieved-doc content past k=3
On both backends, TTFT per added doc-char is roughly constant past k=3: GPU ~100–250 µs/char, 
CPU ~3,500–5,000 µs/char. The GPU↔CPU ratio is stable at ~13–19× across the prefill range, suggesting 
the GPU primarily speeds up the *compute-heavy* prefill phase while decode stays bandwidth-bound on both.

## Data inventory (per `(backend, k)`)

| Backend | k | File | Wall (min) | Runs | Errors |
|---|---:|---|---:|---:|---:|
| CPU | 0 (no-RAG) | `benchmark_20260515T022647.json` | 36.9 | 54 | 0 |
| CPU | 1 | `benchmark_20260514T213337_k1.json` | 38.7 | 54 | 0 |
| CPU | 3 | `benchmark_20260514T221238_k3.json` | 50.2 | 54 | 0 |
| CPU | 5 | `benchmark_20260514T230309_k5.json` | 63.0 | 54 | 0 |
| CPU | 7 | `benchmark_20260515T000622_k7.json` | 66.5 | 54 | 0 |
| CPU | 10 | `benchmark_20260515T011307_k10.json` | 73.2 | 54 | 0 |
| CPU | 15 | `benchmark_20260515T030401_k15.json` | 90.8 | 54 | 0 |
| CPU | 20 | `benchmark_20260515T064042_k20.json` | 58.6 | 54 | 24 |
| GPU | 0 (no-RAG) | `benchmark_20260514T210522.json` | 23.5 | 54 | 0 |
| GPU | 1 | `benchmark_20260514T174502_k1.json` | 23.0 | 54 | 0 |
| GPU | 3 | `benchmark_20260514T180830_k3.json` | 27.3 | 54 | 0 |
| GPU | 5 | `benchmark_20260514T183604_k5.json` | 28.2 | 54 | 0 |
| GPU | 7 | `benchmark_20260514T190438_k7.json` | 30.0 | 54 | 0 |
| GPU | 10 | `benchmark_20260514T193453_k10.json` | 29.1 | 54 | 0 |
| GPU | 15 | `benchmark_20260514T200414_k15.json` | 32.4 | 54 | 0 |
| GPU | 20 | `benchmark_20260514T203653_k20.json` | 22.8 | 54 | 24 |

---

_Source benchmark JSONs live in `evaluation/latency_results/`. 
Aggregation script: `evaluation/aggregate_k_sweep.py`._
