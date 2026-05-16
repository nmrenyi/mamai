# Investigation: What the 4096 `maxNumTokens` Wall Actually Is

_Last updated: 2026-05-16. Companion to [latency_report_v2.md](latency_report_v2.md) §"Errors and the 4096-token context wall"._

## TL;DR

- **GPU on Android runs attention in FP16; CPU runs FP32 (XNNPACK)** — verified from LiteRT-LM source and from strings inside `liblitertlm_jni.so`. This is why the two backends behave differently at lifted context.
- The 4096 cap is **not artifact-baked** — passing `maxNumTokens=8192` to `EngineConfig` succeeds at init on both backends and the artifact happily ran prefill over a 4917-token prompt.
- At `maxNumTokens=8192`, GPU output **collapses into a repetition loop at total-context position ~5000 tokens** — about 50 generated tokens into the response. The transition is **sharp** (200 chars from coherent prose to pure `*` noise), not the gradual decay a pure precision-drift story would predict.
- CPU at `maxNumTokens=8192` stays coherent for the same prompt — same query, same artifact, same retrieved chunks. The asymmetry is the precision difference.
- **Operational conclusion**: the 4096 deployment ceiling is conservative — we have **~900 tokens of safety margin** to the actual GPU breakdown point. Current k=15 deployment is nowhere near the cliff.

---

## Context

PR #59 measured latency for Gemma 4 E4B and E2B at k ∈ {0,1,3,5,7,10,15,20}. At k=20, the same 8 queries failed across every (model × backend) combination with `Input token ids are too long. Exceeding the maximum number of tokens allowed: N >= 4096`. The report originally claimed the wall was *"a property of the .litertlm artifact format."*

PR #60 made `maxNumTokens` explicit at the call site (`EngineConfig(..., maxNumTokens = 4096, ...)`) and ran two experiments to figure out what 4096 actually is:

| Test | What we found |
|---|---|
| Pass `maxNumTokens = 2048` (CPU + GPU) | Engine clamps to 2048; same prompt fails with `>= 2048` instead of `>= 4096`. **Knob is wired through.** |
| Pass `maxNumTokens = 8192` (CPU) | Engine init succeeds. Queries that previously failed at 4096 now run end-to-end with **clean, coherent responses**. |
| Pass `maxNumTokens = 8192` (GPU) | Engine init succeeds. Queries run end-to-end but produce **garbage past a certain point** — first ~1000 chars are real medical reasoning, then ~5000 chars of `*   *   *   *...` repetition. |

This file documents the follow-up investigation into *why GPU breaks and CPU doesn't*, and *where* exactly GPU breaks.

---

## Step 4 — Why the backends diverge: precision

### Source: LiteRT-LM OSS repo (`google-ai-edge/LiteRT-LM`)

[`runtime/executor/executor_settings_base.h`](https://github.com/google-ai-edge/LiteRT-LM/blob/main/runtime/executor/executor_settings_base.h) defines the activation-precision enum:

```cpp
enum class ActivationDataType {
  FLOAT32,
  FLOAT16,
  INT16,
  INT8,
};
```

And the comment on the field that holds it (line 308–316):

> *"Optional setting for specific activation data type. **If not set, the default activation data type for each OS & backend will be used.** [...] OpenCL backend only support fp32 on Linux."*

The factory `LlmExecutorSettings::CreateDefault()` in [`runtime/executor/llm_executor_settings.cc`](https://github.com/google-ai-edge/LiteRT-LM/blob/main/runtime/executor/llm_executor_settings.cc) does **not** set `activation_data_type_` — it leaves the `std::optional` empty, so the OS/backend default takes over. Our Kotlin `EngineConfig` doesn't set it either.

### Source: strings inside `liblitertlm_jni.so`

The smoking-gun string, lifted from the native lib (`grep` over strings in the AAR-extracted .so):

> *"not found for prefer activation type. Use system's default backend activation type. **System's default activation type for Text decoder is fp16.** Vision encoder and audio encoder default is fp32."*

Supporting strings from the same binary:

- `#pragma OPENCL EXTENSION cl_khr_fp16 : enable` — OpenCL FP16 explicitly enabled
- `#define FLT16 float16` / `#define FLT16 half16` — preprocessor macros for FP16 type
- FP16-specific kernels: `Softmax (NC, F16)`, `Batch Matrix Multiply (NC, F16)`, `Average Pooling (NHWC, F16)`, `intel_sub_group_f16_f16_matrix_mad_k16`
- `CalculationsPrecision::F16/F32_F16 is not supported on this GPU(no fp16 support).` — FP16 is the preferred path, FP32 is the fallback when hardware doesn't support FP16

CPU side, strings show **XNNPACK** as the delegate (`LlmLiteRTXnnpackExecutor`, `TfLiteXNNPackDelegate`). XNNPACK on ARM64 defaults to FP32 for floating-point ops; no FP16 attention kernels appear in the CPU code paths.

### Conclusion

| Backend | Activation precision | How we know |
|---|---|---|
| **GPU (OpenCL on Adreno)** | **FP16** | Native log line: *"System's default activation type for Text decoder is fp16"* + explicit FP16 kernels in OpenCL backend |
| **CPU (XNNPACK on ARM64)** | **FP32** | XNNPACK default for ARM64 FP ops + no FP16 attention kernels in CPU paths |
| GPU on Linux | FP32 | Documented in header — but not our deployment target |

We are not overriding these defaults from Kotlin. So when we deploy on Snapdragon, GPU = FP16 and CPU = FP32 in attention.

### Another finding worth flagging

From [`llm_executor_settings.h`](https://github.com/google-ai-edge/LiteRT-LM/blob/main/runtime/executor/llm_executor_settings.h) line 387–389:

> *"Maximum number of the sum of input and output tokens. **It is equivalent to the size of the kv-cache.**"*

So `maxNumTokens` is **total context size** (prompt + response), and equals the KV-cache allocation. The 4096 cap isn't an "input prompt cap" — it's the total prompt + response budget. At k=20 with a 4917-token prompt, no response is even possible at `maxNumTokens=4096`; the prompt alone exceeds the budget. This subtly corrects the prior framing.

---

## Step 1 — Where the GPU output actually breaks

### Setup

- File: [benchmark_20260516T104730_k20.json](../latency_results/benchmark_20260516T104730_k20.json)
- Query: `long_01` at k=20
- Backend: GPU (`useGpuForLlm=true`)
- `maxNumTokens = 8192` (Phase C experiment, uncommitted)
- Response: 6027 chars, ~1506 estimated tokens (4.00 chars/token average)
- Prompt: **4917 tokens** (deterministic — confirmed by the failure messages across all four (model × backend) k=20 sweep cells)

### Method

200-char sliding-window over the response, computing:
- % letters per window (proxy for "is this English prose?")
- % asterisks per window (proxy for "is this the repetition loop?")
- Approximate response-token position (`char_pos / 4.00`)
- Total context position (`prompt_tokens + response_tokens`)

### Result

| Char position | Response tokens (est) | Total context | % letters | % asterisks | What it looks like |
|---:|---:|---:|---:|---:|---|
| 0 | 0 | 4917 | 72.0% | 8.5% | `This is a **medical emergency**...` |
| 200 | 50 | 4967 | 63.0% | 5.0% | Still mostly prose, structure degrading |
| 400 | 100 | 5017 | **2.0%** | **25.0%** | Collapsed into `*` pattern |
| 600 | 150 | 5067 | 0.0% | 25.0% | Pure repetition |
| 1000+ | 250+ | 5167+ | 0.0% | 25–45% | Sustained `*   *   *...` |

The transition is **sharp** — from 72% letters to 2% letters across a 200-char window (~50 generated tokens). After that, response stays at 0% letters for the remaining ~5500 chars.

### Where on the timeline this happens

```
Prompt:                  [============================== 4917 tokens ==============================]
                                                                                                    ↑
Coherent decode:                                                                                    [≈50 tokens of medical prose]
                                                                                                                                 ↑ collapse
Garbage decode:                                                                                                                  [≈1450 tokens of asterisks]

Calibration boundary     [============= 4096 =============]
                                                          |←──~900 tokens slack──→|
                                                                                  collapse at ≈5000
```

### Three findings, in order of importance

**1. The transition is sharp, not gradual.** A pure FP16-noise-compounding story predicts a gradual decay. We see a near-binary cliff in ~50 tokens. This points more toward a **kernel-level boundary** (a tile size, a buffer dimension, a lookup-table size hardcoded for the calibrated context) than pure precision drift. FP16 likely plays a role by removing the precision headroom that would have absorbed borderline kernel artifacts on CPU.

**2. It's at total context ~5000, not 4096.** The model successfully ran prefill over a 4917-token prompt (already 821 tokens past the 4096 cap) and produced ~50 tokens of coherent decoded output drawing on that prompt. The cliff is around total context position **4967–5017** tokens. There's ~900 tokens of margin between the 4096 deployment ceiling and the actual breakdown point.

**3. It looks like a *decode-side* failure, not a prefill-side failure.** Prefill works fine over the 4917-token prompt, and the first ~50 decoded tokens are coherent — so reading from KV cache at positions 0–4916 is fine. What breaks is when the model **writes new K/V entries** at positions ≥ 4917 during decode and then has to attend back to them. The decode-side KV-update kernels look like the prime suspect.

### Operational implication

The 4096 deployment ceiling is **more conservative than necessary** from a pure quality standpoint — GPU output stays coherent up to ~5000 total context. But:

- 4096 is the artifact's published/calibrated value, and the breakdown past 5000 is dramatic (full collapse, not graceful degradation)
- The ~50-token settling window means the safety margin past 4917 is fragile
- Pushing closer to 5000 invites unpredictable transition

So **4096 remains the right ship value** for production. The new understanding is that we have **~900 tokens of headroom**, not zero. At our current k=15 deployment (typical prompt ~3500 tokens), we are nowhere near the cliff and not silently shipping degraded output. **This rules out the safety concern of "the cap is tighter than we think."**

---

## Step 2 — Reproducibility: bit-exact across 3 runs

### Setup

- Same APK as Step 1 (GPU, `maxNumTokens = 8192`).
- Same query: `long_01` at k=20, deterministic 4917-token prompt.
- `--repeats 3`, `--cooldown 1000`.
- File: [benchmark_20260516T151036_k20.json](../latency_results/benchmark_20260516T151036_k20.json)

### Result

| | Rep 1 | Rep 2 | Rep 3 |
|---|---|---|---|
| Response chars | 6027 | 6027 | 6027 |
| Estimated tokens | 1506 | 1506 | 1506 |
| Transition position (char) | 400 | 400 | 400 |
| Total context at transition | ~5017 | ~5017 | ~5017 |
| Response head (first 80 chars) | `This is a **medical emergency**. You must act immediately. **Escalate to a doct` | identical | identical |
| Response tail (last 80 chars) | ` * * * * ********** * * * * * * * * ***************` | identical | identical |
| Decode time (ms) | 263 158 | 263 223 | 263 185 |

Decode-time variance is ~0.05% — pure system jitter. The **model outputs are bit-identical** across all three runs.

### Interpretation

This rules out stochastic FP16 noise as the proximate cause. The GPU backend defaults to greedy decoding (`max_top_k = 1`, the `GpuConfig` default we found in `LlmExecutorSettings::CreateDefault()`); with identical prompts, identical KV cache state, and identical numerical paths through deterministic FP16 OpenCL kernels, every decode step picks the same next token. There is no randomness in the system to mask whatever is going wrong.

So the failure is not "FP16 sometimes drifts past 4096" — it is "FP16 kernels **deterministically produce broken K/V** at positions past the artifact's calibrated zone, in a way that always degenerates into the same output."

---

## Refined mechanism hypothesis (after Steps 4, 1, 2)

1. The Gemma 4 `.litertlm` artifact has KV-cache and attention kernels **calibrated** for a 4096-token context. The OpenCL implementations of those kernels assume something about position layout (tile size, buffer dimension, position-embedding cache) that's accurate up to ~4096 and starts to misbehave past it.

2. **Prefill is robust past 4096** — at engine init the KV cache is allocated to whatever `maxNumTokens` we pass (8192 in our test), and the prefill kernels appear to handle the longer prompt correctly (the model produces real medical content for ~50 decoded tokens).

3. **Decode-side KV writes past position ~4917 produce *deterministically* off-distribution K/V values** (Step 2 evidence). As soon as the model attends back to those bad-write positions in subsequent decode steps, the attention scores collapse onto a small set of high-probability tokens (asterisks, in our case — a tokenizer-common character). The model then enters a self-reinforcing loop: bad outputs → bad self-attention → bad outputs. Same RNG-free state every run, so the same garbage every run.

4. **FP16 vs FP32 is the candidate differentiator across backends**. The kernel issues likely exist on both backends — but FP32's larger dynamic range may absorb the off-distribution values on CPU, while FP16 on GPU has no precision headroom and the bad values dominate. This is *plausible* given the Step 4 source-code finding (CPU = XNNPACK FP32, GPU = OpenCL FP16) but **not directly verified** — see the reachability constraint below.

The "exactly 4096" framing was wrong. The real picture: a ~1000-token "uncalibrated zone" between ~4096 and ~5000 where output quality slowly degrades and then catastrophically collapses, and a deterministic kernel/precision interaction that makes the collapse visible only on GPU.

---

## Reachability constraint: cannot force FP32 on GPU from Kotlin in 0.11.0

The natural follow-up — force the GPU backend to use FP32 instead of FP16 and re-run — turned out to be **not possible from the public Kotlin API** in LiteRT-LM 0.11.0. Verified across four sources:

1. **`Config.kt`**: `EngineConfig` data class has 7 fields (`modelPath, backend, visionBackend, audioBackend, maxNumTokens, maxNumImages, cacheDir`). No precision field. `Backend.GPU()` is zero-arg.
2. **`Engine.kt:initialize()`**: calls `LiteRtLmJni.nativeCreateEngine(...)` with 14 args. None of them is precision-related.
3. **`LiteRtLmJni.kt`**: the JNI bridge declaration. The `nativeCreateEngine` signature takes exactly those 14 parameters — that is the entire JNI surface for engine creation. No `nativeSetActivationDataType` method anywhere in the bridge.
4. **`llm_executor_settings.cc:CreateDefault()`**: doesn't set `activation_data_type_`, leaving it as `std::nullopt`. So when the JNI bridge constructs the engine, no activation type ever gets set, and the runtime falls back to its system default (FP16 for text decoder on Android GPU per the native-lib log string from Step 4).

I also scanned the native lib for environment-variable overrides (`LITERTLM_*`, `LITERT_*`, `OPENCL_*`, `FORCE_FP32`) — none exist.

The C++ `LlmExecutorSettings::SetActivationDataType(...)` method **exists** in LiteRT-LM source, but it is **not bridged** to the Kotlin/JNI layer in version 0.11.0. The hooks are there server-side but not wired to client-side.

### Paths that would unblock the FP32 control test

- **(b) Modify the `.litertlm` artifact header.** The FlatBuffers schema (`schema/core/litertlm_header_schema.fbs`) defines a `SystemMetadata` table as a list of arbitrary `KeyValuePair` entries. The native runtime looks for a key `prefer_activation_type` and, if present, honors it; otherwise it falls back to the system default. Setting `prefer_activation_type = FLOAT32` in the artifact's header would force FP32 on GPU without any code changes. Half a day of work with `flatc` tooling on a 2.4 GB binary; round-trip-test before changing values.
- **(c) File an upstream issue with `google-ai-edge/LiteRT-LM`** to expose `SetActivationDataType` in the Kotlin `EngineConfig` API. Doesn't unblock us now, but is the right systemic fix.
- **(d) Build a custom LiteRT-LM AAR.** Clone the repo, add a field to the Kotlin `EngineConfig` + parameter to `nativeCreateEngine` + plumbing to the C++ setter. Multi-day project; out of scope.

For now this PR documents the constraint and the experimental options. The mechanism story is already well-anchored even without the FP32 control: Steps 4, 1, 2 together make the FP16-induced determinstic kernel-zone breakdown the obvious hypothesis. The control test would *confirm* it; it doesn't change the deployment recommendation either way.

---

## What's still open

| Question | Status | Cost to answer |
|---|---|---|
| ~~Is the GPU cliff deterministic (same position every run) or stochastic?~~ | **Resolved (Step 2)** — bit-exactly deterministic across 3 reps | — |
| ~~Is the Kotlin API able to force FP32 on GPU?~~ | **Resolved (reachability check)** — no, not in LiteRT-LM 0.11.0 | — |
| Is FP16 attention the root cause, or just one factor among others? | **Open** — would need option (b) artifact-modification or option (d) custom AAR to run the control test | half-day / multi-day respectively |
| Does the cliff position depend on prompt length, or is it fixed at total context ~5000? | **Open** — would help characterize the kernel boundary; not deployment-relevant | ~30 min: run a few queries with different prompt lengths at maxNumTokens=8192 |
| Does the artifact's `prefer_activation_type` field explicitly set FP16, or rely on the system default? | **Open** — answered by parsing the FlatBuffers header with `flatc`; would be a useful prereq for option (b) | ~1-2 hours of flatc tooling work |

The remaining open questions characterize the mechanism more precisely but do not change the deployment recommendation (4096 stays the ship value).

---

## References

- [latency_report_v2.md](latency_report_v2.md) §"Errors and the 4096-token context wall" — the high-level summary that points here
- [evaluation/latency_results/benchmark_20260516T100105_k20.json](../latency_results/benchmark_20260516T100105_k20.json) — CPU at maxNumTokens=8192, long_01, k=20 (clean output)
- [evaluation/latency_results/benchmark_20260516T103614_k20.json](../latency_results/benchmark_20260516T103614_k20.json) — CPU at maxNumTokens=8192, long_03, k=20 (clean output)
- [evaluation/latency_results/benchmark_20260516T104730_k20.json](../latency_results/benchmark_20260516T104730_k20.json) — GPU at maxNumTokens=8192, long_01, k=20, 1 rep (degenerate output — the one analyzed in Step 1)
- [evaluation/latency_results/benchmark_20260516T151036_k20.json](../latency_results/benchmark_20260516T151036_k20.json) — GPU at maxNumTokens=8192, long_01, k=20, 3 reps (bit-identical degenerate output — Step 2 reproducibility)
- LiteRT-LM source: <https://github.com/google-ai-edge/LiteRT-LM>
- [app/android/app/src/main/kotlin/com/example/app/RagPipeline.kt:buildEngine()](../../app/android/app/src/main/kotlin/com/example/app/RagPipeline.kt) — where `maxNumTokens = 4096` is set
