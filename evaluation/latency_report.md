# On-Device LLM Latency Comparison

**Device**: Google Pixel 7 (Tensor G2, 8 GB RAM, Android 16)
**Date**: 2026-02-26
**Build**: Release APK (optimized native code)
**CPU state**: Fully recovered (big cores at 2850 MHz) before each test

## Results

| | MedGemma 4B (llama.cpp) | Gemma 3n E4B (llama.cpp) | Gemma 3n E4B (MediaPipe) |
|---|---|---|---|
| **Branch** | `llama-cpp` | `llama-cpp` | `main` |
| **Model file** | `medgemma-4b-it-Q4_0.gguf` | `gemma-3n-E4B-it-Q4_0.gguf` | `gemma-3n-E4B-it-int4.task` |
| **Model size** | 2.2 GB | 4.1 GB | 4.1 GB |
| **Quantization** | Q4_0 (GGUF) | Q4_0 (GGUF) | int4 (.task) |
| **APK size** | 57 MB | 57 MB | 164 MB |
| **Backend** | CPU only | CPU only | CPU (GPU available) |
| **Model load** | 5.0 s | FAILED | 1.2 s |
| **Prefill (TTFT)** | 50.0 s (415 tokens, 8.3 t/s) | N/A | 16.4 s |
| **Decode** | 18.2 s (78 tokens, 4.3 t/s) | N/A | 19.8 s (~103 tokens, ~5.2 t/s) |
| **Total query** | 68.2 s | N/A | 36.2 s |
| **Response** | 405 chars | N/A | 411 chars |

## Key Findings

### 1. Gemma 3n is not supported in llama.cpp b5220

Our pinned llama.cpp version (tag `b5220`, April 2025) only supports `gemma`, `gemma2`, and `gemma3` architectures. Gemma 3n (`gemma3n`) is a newer architecture added in [PR #14400](https://github.com/ggml-org/llama.cpp/pull/14400) (merged June 26, 2025). The minimum version is **b5769**; the latest is **b8157** (Feb 2026). Text support is stable (8 months of fixes, no open bugs). GGUF models are available from [ggml-org](https://huggingface.co/ggml-org/gemma-3n-E4B-it-GGUF) and [Unsloth](https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF).

### 2. MediaPipe prefill is 3x faster

MediaPipe's `addQueryChunk()` returns in 6 ms (it only queues the prompt), but actual prefill happens lazily inside `generateResponseAsync()`. Measured via time-to-first-token callback, the real prefill is **16.4 s**. llama.cpp performs a synchronous **50.0 s** prefill before producing any output. MediaPipe's prefill is ~3x faster.

### 3. Decode throughput favours MediaPipe slightly

- llama.cpp (MedGemma 4B): **4.3 tokens/s**
- MediaPipe (Gemma 3n E4B): **~5.2 tokens/s**

Both produce text at a readable pace once streaming begins.

### 4. MediaPipe is ~2x faster end-to-end

Total query time: **36.2 s** (MediaPipe) vs **68.2 s** (llama.cpp) — MediaPipe is 1.9x faster overall, despite running a larger model (4.1 GB vs 2.2 GB).

### 5. Thermal throttling is a major factor

The Pixel 7's Tensor G2 throttles aggressively under sustained CPU load:
- Big cores (Cortex-X1): 2850 MHz → 984 MHz (34% of max) after ~60 s of inference
- Model loading alone heats the CPU enough to throttle subsequent inference
- Debug builds (`flutter run`) compile native code with `-O0`, making inference 5-10x slower

## Observations

**Advantages of llama.cpp**:
- Can run any GGUF model (model flexibility)
- MedGemma 4B may produce better medical answers than Gemma 3n (not evaluated here)
- Smaller APK (57 MB vs 164 MB — no bundled MediaPipe native libs)
- Upgrading to b5769+ would add Gemma 3n support, enabling same-model comparison

**Advantages of MediaPipe**:
- 3x faster prefill (16.4 s vs 50.0 s)
- Faster total query time (36.2 s vs 68.2 s)
- Faster model load (1.2 s vs 5.0 s)
- Higher decode throughput (~5.2 t/s vs 4.3 t/s)
- Optimized for Tensor chips by Google
- GPU backend available (not tested, but could further improve speed)

## Methodology

Each test followed the same procedure:
1. Force-stop the app and wait for CPU to fully recover (big cores at 2850 MHz max)
2. Install release APK and clear logcat
3. Launch app, wait for model to load
4. Submit a single short query with retrieval disabled
5. Record timing from `adb logcat -s mam-ai`

Test queries were similar short prompts ("I am in pain", "I feel painful", "I feel depressed"). Retrieval was disabled to isolate LLM latency from embedding/vector search overhead.

MediaPipe prefill was measured via time-to-first-token callback (first non-empty `partial` in `generateResponseAsync`), since `addQueryChunk()` only queues the prompt and returns immediately.

## Recommendation

**Stick with MediaPipe + Gemma 3n** for now. It is ~2x faster end-to-end with 3x faster prefill.

Consider llama.cpp if:
- MedGemma's medical accuracy is significantly better than Gemma 3n (requires separate quality evaluation)
- Upgrading llama.cpp to b5769+ and running Gemma 3n on both backends to make a fair same-model comparison
- The prefill bottleneck can be mitigated (e.g., prompt caching, shorter system prompts)
