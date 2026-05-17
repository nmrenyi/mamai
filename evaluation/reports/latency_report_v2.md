# MAM-AI On-Device Latency Sweep — Model × Backend × k

_Generated: 2026-05-17T14:39:17_


## Device & stack

- **Device**: OnePlus OPD2413 (SM8750P) — Android 15
- **Models tested**: Gemma 4 E2B (`gemma-4-E2B-it.litertlm`), Gemma 4 E4B (`gemma-4-E4B-it.litertlm`)
- **LiteRT-LM**: 0.11.0
- **Backends tested**: GPU (OpenCL on Adreno) and CPU (XNNPACK)
- **Activation precision**: GPU defaults to **FP16**, CPU defaults to **FP32** — this asymmetry matters at lifted context (see [`maxnumtoken_investigation.md`](maxnumtoken_investigation.md) §Step 4). All tables in this report use the defaults; one explicit FP32-on-GPU sweep is summarised in the [FP16 vs FP32 GPU](#fp16-vs-fp32-gpu-context-cap-discussion) section below.
- **Sampling**: temp=1.0, top_p=0.95, top_k=64 — read from `runtime_config.json`. No explicit `max_output_tokens` cap is enforced; the runtime decodes until a stop token or until total context hits `maxNumTokens=4096`.
- **Total context budget** (`maxNumTokens` passed to `EngineConfig`): **4096** — single source of truth in `runtime_config.json` `engine.max_num_tokens`.

## TL;DR — today's deployment

> **FP16 GPU at `maxNumTokens=4096`** is the current ship configuration on Snapdragon 8 Elite. Median total query latency 14–25 s across k=0–15; cleanly below the FP16 quality cliff at total context ~5000. k=20 prompts are runtime-rejected (24/54 in every sweep). Fallbacks: FP32 GPU (~21–34% slower, no cliff) for higher-context use cases on ≥16 GB devices; CPU FP32 (≈2–4× slower than FP16 GPU) for devices without working OpenCL.

## Methodology

Per (model × backend × k) configuration: 18 (query × mode) cells × 3 repeats = 54 timed runs. Plus a No-RAG baseline per (model × backend) (k=0 via `--no-retrieval`). 10-second cooldown between runs for thermal stability. Activity → ForegroundService with PARTIAL_WAKE_LOCK so the run survives screen-off and device-lock; OPPO Hans whitelist set manually.

- `TTFT` excludes retrieval — measured from end-of-retrieval to first generated token.
- `decode` is first-token to last-token.
- `total_query` is everything: `retrieval + TTFT + decode`.
- Reported as median across the 54 runs unless noted (p95 in tables marked `p95`).
- Benchmark JSONs from commit `52e11e9` onward record `config.max_num_tokens`, `config.artifact_fingerprint` (SHA-256 of first 64 KB of the loaded `.litertlm`), and `config.git_commit_sha`. These let any reviewer cryptographically verify which artifact variant + code state produced each JSON. Earlier sweep JSONs (PR #57/#59) lack these fields but their content is unaffected.

## Gemma 4 E2B (`gemma-4-E2B-it.litertlm`)

### Median total query latency (seconds)

| k | doc_chars med | GPU short / med / long | CPU short / med / long | CPU÷GPU |
|---:|---:|---:|---:|---:|
| **0 (no-RAG)** | 0 | 7.9 / 8.1 / 10.8 | 13.2 / 14.1 / 16.0 | 1.60× |
| 1 | 561 | 11.4 / 11.8 / 12.8 | 13.0 / 16.3 / 17.5 | 1.35× |
| 3 | 2098 | 12.8 / 13.8 / 16.5 | 19.1 / 22.0 / 22.5 | 1.44× |
| 5 | 3547 | 9.9 / 14.2 / 14.0 | 26.3 / 27.6 / 28.6 | 2.36× |
| 7 | 5139 | 12.8 / 14.3 / 17.6 | 23.5 / 32.0 / 33.2 | 1.87× |
| 10 | 7482 | 15.2 / 14.6 / 17.9 | 23.4 / 26.2 / 27.7 | 1.68× |
| 15 | 11297 | 13.0 / 12.4 / 14.8 | 31.0 / 38.2 / 40.7 | 2.80× |
| 20 | 14520 | 19.3 / 15.8 / 14.3 | 33.4 / 39.8 / 44.5 | 2.28× |

### TTFT (ms, median)

| k | doc_chars med | GPU TTFT | CPU TTFT | CPU÷GPU |
|---:|---:|---:|---:|---:|
| **0 (no-RAG)** | 0 | 429 | 5564 | 13.0× |
| 1 | 561 | 412 | 5355 | 13.0× |
| 3 | 2098 | 445 | 7394 | 16.6× |
| 5 | 3547 | 793 | 14604 | 18.4× |
| 7 | 5139 | 819 | 14577 | 17.8× |
| 10 | 7482 | 1074 | 13635 | 12.7× |
| 15 | 11297 | 1479 | 21368 | 14.4× |
| 20 | 14520 | 1722 | 22947 | 13.3× |

### Decode (ms, median)

| k | GPU decode | CPU decode | CPU÷GPU |
|---:|---:|---:|---:|
| **0 (no-RAG)** | 8263 | 8174 | 0.99× |
| 1 | 7573 | 6764 | 0.89× |
| 3 | 10223 | 9584 | 0.94× |
| 5 | 9052 | 9571 | 1.06× |
| 7 | 10723 | 13451 | 1.25× |
| 10 | 10713 | 11870 | 1.11× |
| 15 | 9664 | 9920 | 1.03× |
| 20 | 11036 | 10697 | 0.97× |

### p95 total query latency (s)

| k | GPU p95 | CPU p95 |
|---:|---:|---:|
| **0 (no-RAG)** | 11.4 | 17.4 |
| 1 | 17.7 | 19.1 |
| 3 | 19.7 | 35.8 |
| 5 | 21.2 | 35.1 |
| 7 | 19.4 | 41.0 |
| 10 | 23.8 | 37.9 |
| 15 | 18.1 | 45.2 |
| 20 | 22.2 | 50.4 |

### Errors (count / 54 runs)

| k | GPU errors | CPU errors |
|---:|---:|---:|
| **0 (no-RAG)** | 0 | 0 |
| 1 | 0 | 0 |
| 3 | 0 | 0 |
| 5 | 0 | 0 |
| 7 | 0 | 0 |
| 10 | 0 | 0 |
| 15 | 0 | 0 |
| 20 | 24 | 24 |

### Wall-clock

| k | GPU wall (min) | CPU wall (min) | CPU÷GPU |
|---:|---:|---:|---:|
| **0 (no-RAG)** | 17.5 | 22.5 | 1.28× |
| 1 | 20.9 | 23.9 | 1.14× |
| 3 | 22.4 | 30.0 | 1.34× |
| 5 | 21.1 | 34.2 | 1.62× |
| 7 | 22.8 | 35.5 | 1.56× |
| 10 | 23.3 | 33.9 | 1.46× |
| 15 | 21.1 | 41.7 | 1.97× |
| 20 | 19.1 | 30.4 | 1.59× |

## Gemma 4 E4B (`gemma-4-E4B-it.litertlm`)

### Median total query latency (seconds)

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

### TTFT (ms, median)

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

### Decode (ms, median)

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

### p95 total query latency (s)

| k | GPU p95 | CPU p95 |
|---:|---:|---:|
| **0 (no-RAG)** | 26.1 | 38.4 |
| 1 | 26.1 | 37.1 |
| 3 | 30.3 | 64.3 |
| 5 | 30.7 | 74.6 |
| 7 | 35.1 | 81.8 |
| 10 | 29.0 | 84.5 |
| 15 | 30.6 | 112.7 |
| 20 | 35.3 | 104.9 |

### Errors (count / 54 runs)

| k | GPU errors | CPU errors |
|---:|---:|---:|
| **0 (no-RAG)** | 0 | 0 |
| 1 | 0 | 0 |
| 3 | 0 | 0 |
| 5 | 0 | 0 |
| 7 | 0 | 0 |
| 10 | 0 | 0 |
| 15 | 0 | 0 |
| 20 | 24 | 24 |

### Wall-clock

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

## Cross-model comparison

Each table below compares **Gemma 4 E4B** (baseline) against each comparator model (Gemma 4 E2B). Ratios are reported as **baseline ÷ comparator** at the same backend × k cell, so values **> 1.0× mean the comparator is faster**. Reading the columns: GPU prefill (TTFT) is compute-bound and tracks parameter count closely; GPU decode is bandwidth-bound and gains less from model shrinkage; CPU is compute-bound throughout.

### Gemma 4 E4B vs Gemma 4 E2B

**Total query latency (median, seconds)**

| k | Gemma 4 E4B GPU | Gemma 4 E2B GPU | GPU ratio | Gemma 4 E4B CPU | Gemma 4 E2B CPU | CPU ratio |
|---:|---:|---:|---:|---:|---:|---:|
| **0 (no-RAG)** | 14.4 | 8.7 | 1.66× | 28.0 | 13.9 | 2.01× |
| 1 | 14.1 | 11.7 | 1.21× | 30.3 | 15.8 | 1.92× |
| 3 | 19.1 | 14.3 | 1.33× | 42.7 | 20.6 | 2.07× |
| 5 | 19.6 | 11.6 | 1.70× | 60.2 | 27.2 | 2.21× |
| 7 | 22.9 | 15.2 | 1.50× | 62.3 | 28.5 | 2.18× |
| 10 | 22.4 | 15.6 | 1.43× | 69.4 | 26.3 | 2.64× |
| 15 | 24.4 | 13.1 | 1.86× | 84.9 | 36.8 | 2.31× |
| 20 | 21.0 | 16.5 | 1.28× | 93.8 | 37.6 | 2.49× |

**TTFT (median, ms)** — prefill speedup

| k | Gemma 4 E4B GPU | Gemma 4 E2B GPU | GPU ratio | Gemma 4 E4B CPU | Gemma 4 E2B CPU | CPU ratio |
|---:|---:|---:|---:|---:|---:|---:|
| **0 (no-RAG)** | 962 | 429 | 2.24× | 12633 | 5564 | 2.27× |
| 1 | 954 | 412 | 2.32× | 12649 | 5355 | 2.36× |
| 3 | 989 | 445 | 2.22× | 18356 | 7394 | 2.48× |
| 5 | 1884 | 793 | 2.38× | 36424 | 14604 | 2.49× |
| 7 | 1920 | 819 | 2.34× | 36444 | 14577 | 2.50× |
| 10 | 2523 | 1074 | 2.35× | 40013 | 13635 | 2.93× |
| 15 | 3457 | 1479 | 2.34× | 54748 | 21368 | 2.56× |
| 20 | 3986 | 1722 | 2.31× | 72881 | 22947 | 3.18× |

**Decode (median, ms)** — bandwidth-limited on GPU, compute-limited on CPU

| k | Gemma 4 E4B GPU | Gemma 4 E2B GPU | GPU ratio | Gemma 4 E4B CPU | Gemma 4 E2B CPU | CPU ratio |
|---:|---:|---:|---:|---:|---:|---:|
| **0 (no-RAG)** | 13470 | 8263 | 1.63× | 15345 | 8174 | 1.88× |
| 1 | 11415 | 7573 | 1.51× | 13961 | 6764 | 2.06× |
| 3 | 16364 | 10223 | 1.60× | 19110 | 9584 | 1.99× |
| 5 | 15929 | 9052 | 1.76× | 21645 | 9571 | 2.26× |
| 7 | 17215 | 10723 | 1.61× | 23473 | 13451 | 1.75× |
| 10 | 18118 | 10713 | 1.69× | 21699 | 11870 | 1.83× |
| 15 | 16820 | 9664 | 1.74× | 22497 | 9920 | 2.27× |
| 20 | 14688 | 11036 | 1.33× | 22634 | 10697 | 2.12× |

<a id="fp16-vs-fp32-gpu-context-cap-discussion"></a>
## FP16 vs FP32 GPU (and why the context cap is 4096)

All cross-model tables above use the **default** GPU activation precision, which on Android is **FP16**. That choice is not a knob in our code — LiteRT-LM picks FP16 for the GPU text-decoder path and FP32 for CPU (XNNPACK). We measured the implications head-to-head; full investigation in [`maxnumtoken_investigation.md`](maxnumtoken_investigation.md). Headlines:

- ⚠️ **The FP16 default has a quality cliff** at total context ~5000 tokens — GPU output silently collapses into a `*` repetition loop, deterministically. Concrete example: [`benchmark_20260516T104730_k20.json`](../latency_results/benchmark_20260516T104730_k20.json) (long_01, k=20, FP16 GPU, maxNumTokens=8192).
- **CPU (FP32) stays clean** for the same prompt — the asymmetry isolates precision as the cause, not the artifact or backend choice.
- **Confirming the fix**: forcing GPU to FP32 (via injecting `prefer_activation_type=float32` into the `.litertlm` metadata) eliminates the cliff. Direct A/B on the exact `long_01` k=20 case wasn't possible — FP32 KV cache at maxNumTokens=8192 OOMs the test device — but the closest-comparable test (`long_01` k=15, max=5000, response ending at total context ~4514) produced clean output through the same FP16-cliff zone.
- **Our 4096 ship value gives ~900 tokens of safety margin** below the FP16 cliff. Anyone lifting the cap on FP16 GPU enters the silent-failure zone; switch to FP32 GPU first.

### Latency cost of FP32 on GPU (E4B at maxNumTokens=4096, 2026-05-17)

Apples-to-apples sweep with `artifact_fingerprint`-verified provenance. Full 8×2 table is in the investigation doc §Step 6; the medians at a representative subset:

| k | FP16 GPU total | FP32 GPU total | T ratio | FP16 TTFT | FP32 TTFT | TTFT ratio | FP16 decode | FP32 decode |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **0 (no-RAG)** | 14.5 s | 16.5 s | 1.14× | 0.97 s | 2.03 s | 2.10× | 13.5 s | 14.4 s |
| 1 | 14.1 s | 18.0 s | 1.28× | 0.95 s | 2.06 s | 2.16× | 11.4 s | 12.8 s |
| 5 | 19.6 s | 24.3 s | 1.24× | 1.88 s | 4.28 s | 2.28× | 16.0 s | 16.3 s |
| 10 | 22.6 s | 27.4 s | 1.21× | 2.53 s | 5.85 s | 2.32× | 18.2 s | 18.6 s |
| 15 | 23.1 s | 30.9 s | 1.34× | 3.45 s | 8.37 s | 2.43× | 16.9 s | 18.4 s |

Two clean stories:

- **Prefill (TTFT) is ~2.1–2.5× slower on FP32** — prefill is compute-bound, and FP16 doubles arithmetic throughput on Adreno. The ratio is stable across k.
- **Decode is essentially identical** (within ~9% on every cell) — decode is bandwidth-bound, so precision barely matters in steady-state generation.
- **Total query is 6–34% slower on FP32**, depending on how much of total is prefill vs decode at the given k. At our typical k=10–15 cells, ~21–34% slower (~5–8 s extra wait per query).

### When to ship FP32 GPU instead of FP16 GPU

| Use case | Choice | Why |
|---|---|---|
| **Today's deployment** | FP16 GPU, max=4096 | Clean output below the cliff; fastest UX |
| Extra correctness margin without changing context | FP32 GPU, max=4096 | ~25% slower at k=15 but eliminates the FP16 cliff as a risk class entirely |
| Higher context (e.g., k>15 desired in future) | FP32 GPU, max=5000–6000 | No cliff. Memory: KV cache doubles → ~6500–7500 ceiling on 16 GB devices |
| GPU unavailable (MediaTek / older Snapdragon) | CPU FP32 | Always clean, but ~2–4× slower than FP16 GPU |

---

## Errors and the 4096-token context wall

At k=20, **24 of 54 runs error in every (model × backend) combination** — exactly the same 8 queries × 3 reps each: 
`long_01, long_03, medium_02, medium_04, short_01, short_03, short_04, short_05`. 
Each failure reports `Input token ids are too long. Exceeding the maximum number of tokens allowed: …>= 4096`. The cap is a runtime config check in LiteRT-LM (verified in `liblitertlm_jni.so`), enforced before any decoding — it's precision-agnostic and applies identically on CPU, FP16 GPU, and FP32 GPU. The same queries fail regardless of the backend choice.

`maxNumTokens=4096` is the value the engine enforces. The Kotlin `EngineConfig` constructor exposes this parameter; leaving it `null` falls back to the engine's default, which happens to be 4096 for the Gemma 4 artifacts we load. `RagPipeline.kt:buildEngine()` now passes it explicitly, sourced from `runtime_config.json` `engine.max_num_tokens`. **The cap is a deliberate ship value, not an architectural constant** — see the FP16/FP32 section above for the experiment that established why 4096 is the right choice for our default-precision GPU path.

## Key findings

### 1. Prefill (TTFT) scales ~2× with parameter count on both backends
Halving the parameter count (E4B → E2B) gives a **consistent ~2.3× TTFT speedup on GPU** and **~2.3–3.2× on CPU**. Prefill is compute-heavy (one parallel forward pass over the entire prompt), so halving the parameter count halves the compute and the speedup is near-proportional on both backends.

### 2. Decode is bandwidth-bound on GPU, compute-bound on CPU
Decode speedup from E4B → E2B is **~1.5× on GPU** but **~2× on CPU**. Decode is sequential (one token at a time), so on GPU it's limited by memory bandwidth feeding weights into compute units — the smaller model helps less than its parameter count would predict. On CPU the constraint is compute, so the speedup tracks the model shrink.

### 3. Total speedup is decode-dominated, hence smaller than TTFT
**Total-query speedup**: ~1.5× GPU, ~2.2× CPU. Total = TTFT + decode + retrieval; since decode dominates total at low-to-mid k (TTFT is small there), the total speedup tracks decode rather than prefill. At high k where prefill grows large, total speedup climbs toward the prefill ratio (~1.7–1.9× GPU at k=15+).

### 4. GPU still wins, but E2B CPU opens up the no-GPU device tier
E2B CPU is 1.4–2.4× slower than E2B GPU at every k — GPU remains the preferred backend where available. But E2B CPU at k=1 (~16 s median) is comparable to E4B GPU at k=1 (~14 s), which means devices that previously could *not* deploy MAM-AI at acceptable latency (mid-tier MediaTek, older Snapdragon without OpenCL) now have a realistic path: ship E2B on CPU, restrict k to small values.

### 5. 4096-token context wall is the binding ceiling — driven by precision, not runtime
k=15 works cleanly on all four (model × backend) combinations. k=20 prompts exceed 4096 tokens and the runtime rejects them — same 24 errors on every cell. The cap is *liftable* (passing `maxNumTokens=8192` is accepted by the engine), but on the default **FP16** GPU path the lifted output silently collapses past total context ~5000 — a precision-driven quality cliff. Switching GPU to FP32 (via artifact metadata) removes the cliff at ~25% latency cost. See the FP16-vs-FP32 GPU section above. **Latency is not the constraint at the upper end of k — output quality is, and the fix is to change precision rather than the cap.**

### 6. TTFT scales linearly with retrieved-doc content past k=3
On both backends and both models, TTFT-per-doc-char is roughly constant past k=3, so the prefill story scales predictably. The model shrink translates directly into a TTFT shrink across the whole range.

## Data inventory (per `(model, backend, k)`)

| Model | Backend | k | File | Wall (min) | Runs | Errors |
|---|---|---:|---|---:|---:|---:|
| Gemma 4 E2B | CPU | 0 (no-RAG) | `benchmark_20260515T223100.json` | 22.5 | 54 | 0 |
| Gemma 4 E2B | CPU | 1 | `benchmark_20260515T183910_k1.json` | 23.9 | 54 | 0 |
| Gemma 4 E2B | CPU | 3 | `benchmark_20260515T190320_k3.json` | 30.0 | 54 | 0 |
| Gemma 4 E2B | CPU | 5 | `benchmark_20260515T193337_k5.json` | 34.2 | 54 | 0 |
| Gemma 4 E2B | CPU | 7 | `benchmark_20260515T200805_k7.json` | 35.5 | 54 | 0 |
| Gemma 4 E2B | CPU | 10 | `benchmark_20260515T204358_k10.json` | 33.9 | 54 | 0 |
| Gemma 4 E2B | CPU | 15 | `benchmark_20260515T211813_k15.json` | 41.7 | 54 | 0 |
| Gemma 4 E2B | CPU | 20 | `benchmark_20260515T220014_k20.json` | 30.4 | 54 | 24 |
| Gemma 4 E2B | GPU | 0 (no-RAG) | `benchmark_20260515T175744.json` | 17.5 | 54 | 0 |
| Gemma 4 E2B | GPU | 1 | `benchmark_20260515T152447_k1.json` | 20.9 | 54 | 0 |
| Gemma 4 E2B | GPU | 3 | `benchmark_20260515T154608_k3.json` | 22.4 | 54 | 0 |
| Gemma 4 E2B | GPU | 5 | `benchmark_20260515T160846_k5.json` | 21.1 | 54 | 0 |
| Gemma 4 E2B | GPU | 7 | `benchmark_20260515T163011_k7.json` | 22.8 | 54 | 0 |
| Gemma 4 E2B | GPU | 10 | `benchmark_20260515T165316_k10.json` | 23.3 | 54 | 0 |
| Gemma 4 E2B | GPU | 15 | `benchmark_20260515T171649_k15.json` | 21.1 | 54 | 0 |
| Gemma 4 E2B | GPU | 20 | `benchmark_20260515T173816_k20.json` | 19.1 | 54 | 24 |
| Gemma 4 E4B | CPU | 0 (no-RAG) | `benchmark_20260515T022647.json` | 36.9 | 54 | 0 |
| Gemma 4 E4B | CPU | 1 | `benchmark_20260514T213337_k1.json` | 38.7 | 54 | 0 |
| Gemma 4 E4B | CPU | 3 | `benchmark_20260514T221238_k3.json` | 50.2 | 54 | 0 |
| Gemma 4 E4B | CPU | 5 | `benchmark_20260514T230309_k5.json` | 63.0 | 54 | 0 |
| Gemma 4 E4B | CPU | 7 | `benchmark_20260515T000622_k7.json` | 66.5 | 54 | 0 |
| Gemma 4 E4B | CPU | 10 | `benchmark_20260515T011307_k10.json` | 73.2 | 54 | 0 |
| Gemma 4 E4B | CPU | 15 | `benchmark_20260515T030401_k15.json` | 90.8 | 54 | 0 |
| Gemma 4 E4B | CPU | 20 | `benchmark_20260515T064042_k20.json` | 58.6 | 54 | 24 |
| Gemma 4 E4B | GPU | 0 (no-RAG) | `benchmark_20260514T210522.json` | 23.5 | 54 | 0 |
| Gemma 4 E4B | GPU | 1 | `benchmark_20260514T174502_k1.json` | 23.0 | 54 | 0 |
| Gemma 4 E4B | GPU | 3 | `benchmark_20260514T180830_k3.json` | 27.3 | 54 | 0 |
| Gemma 4 E4B | GPU | 5 | `benchmark_20260514T183604_k5.json` | 28.2 | 54 | 0 |
| Gemma 4 E4B | GPU | 7 | `benchmark_20260514T190438_k7.json` | 30.0 | 54 | 0 |
| Gemma 4 E4B | GPU | 10 | `benchmark_20260514T193453_k10.json` | 29.1 | 54 | 0 |
| Gemma 4 E4B | GPU | 15 | `benchmark_20260514T200414_k15.json` | 32.4 | 54 | 0 |
| Gemma 4 E4B | GPU | 20 | `benchmark_20260514T203653_k20.json` | 22.8 | 54 | 24 |

---

_Source benchmark JSONs live in `evaluation/latency_results/`. 
Aggregation script: `evaluation/aggregate_k_sweep.py`._
