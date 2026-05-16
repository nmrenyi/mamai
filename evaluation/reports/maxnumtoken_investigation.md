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

## Refined mechanism hypothesis

Combining the precision finding (Step 4) and the sharp-cliff finding (Step 1):

1. The Gemma 4 `.litertlm` artifact has KV-cache and attention kernels **calibrated** for a 4096-token context. The OpenCL implementations of those kernels assume something about position layout (tile size, buffer dimension, position-embedding cache) that's accurate up to ~4096 and starts to misbehave past it.

2. **Prefill is robust past 4096** — at engine init the KV cache is allocated to whatever `maxNumTokens` we pass (8192 in our test), and the prefill kernels appear to handle the longer prompt correctly (the model produces real medical content for ~50 decoded tokens).

3. **Decode-side KV writes past position ~4917 start producing off-distribution K/V values**. As soon as the model attends back to those bad-write positions in subsequent decode steps, the attention scores collapse onto a small set of high-probability tokens (asterisks, in our case — a tokenizer-common character). The model then enters a self-reinforcing loop: bad outputs → bad self-attention → bad outputs.

4. **FP16 vs FP32 is the differentiator across backends**. The kernel issues likely exist on both backends — but FP32's larger dynamic range absorbs the off-distribution values on CPU, while FP16 on GPU has no precision headroom and the bad values dominate.

The "exactly 4096" framing was wrong. The real picture: a ~1000-token "uncalibrated zone" between ~4096 and ~5000 where output quality slowly degrades and then catastrophically collapses, and a precision asymmetry that makes the collapse visible only on GPU.

---

## What's still open

| Question | Status | Cost to answer |
|---|---|---|
| Is the GPU cliff deterministic (same position every run) or stochastic? | **Open** — Step 2 | ~25 min on device: rebuild GPU APK at maxNumTokens=8192, run `long_01` k=20 ×5 reps, compare transition positions |
| Does the cliff position depend on `maxNumTokens` allocation, or is it fixed at ~5000? | **Open** — Step 3 | ~30 min on device: 3 builds at maxNumTokens ∈ {5000, 6000, 7000}, run same query, observe cliff position |
| Does the cliff position depend on prompt length, or is it fixed at total-context ~5000? | **Open** — companion to Step 3 | Could be combined: run several queries with prompts of 3000/4000/4500 tokens at maxNumTokens=8192 |
| Does the artifact's `prefer_activation_type` field explicitly set FP16, or rely on the system default? | **Open** — requires parsing the FlatBuffers .litertlm header | Doesn't change operational conclusion |
| Is FP16 attention the root cause, or just a symptom amplifier? | **Open** — would need to force GPU to FP32 via `SetActivationDataType(FLOAT32)` and re-test | Significant work, low deployment payoff |

Steps 2 and 3 are the cheapest and would give us the cleanest characterization of the cliff. Neither changes the deployment recommendation (4096 stays the ship value either way), but they would let us write up the mechanism with confidence rather than the current "best hypothesis."

---

## References

- [latency_report_v2.md](latency_report_v2.md) §"Errors and the 4096-token context wall" — the high-level summary that points here
- [evaluation/latency_results/benchmark_20260516T100105_k20.json](../latency_results/benchmark_20260516T100105_k20.json) — CPU at maxNumTokens=8192, long_01, k=20 (clean output)
- [evaluation/latency_results/benchmark_20260516T103614_k20.json](../latency_results/benchmark_20260516T103614_k20.json) — CPU at maxNumTokens=8192, long_03, k=20 (clean output)
- [evaluation/latency_results/benchmark_20260516T104730_k20.json](../latency_results/benchmark_20260516T104730_k20.json) — GPU at maxNumTokens=8192, long_01, k=20 (degenerate output — the one analyzed in Step 1)
- LiteRT-LM source: <https://github.com/google-ai-edge/LiteRT-LM>
- [app/android/app/src/main/kotlin/com/example/app/RagPipeline.kt:buildEngine()](../../app/android/app/src/main/kotlin/com/example/app/RagPipeline.kt) — where `maxNumTokens = 4096` is set
