# On-Device LLM Latency Comparison

**Device**: Google Pixel 7 (Tensor G2, 8 GB RAM, Android 16)
**Date**: 2026-02-26
**Build**: Release APK (optimized native code)
**CPU state**: Fully recovered (big cores at 2850 MHz) before each test

## Results

| | MedGemma 4B (llama.cpp b5220) | MedGemma 4B (llama.cpp b8157) | Gemma 3n E4B (llama.cpp b8157) | Gemma 3n E4B (MediaPipe) |
|---|---|---|---|---|
| **Branch** | `llama-cpp` | `llama-cpp` | `llama-cpp` | `main` |
| **Model file** | `medgemma-4b-it-Q4_0.gguf` | `medgemma-4b-it-Q4_0.gguf` | `gemma-3n-E4B-it-Q4_0.gguf` | `gemma-3n-E4B-it-int4.task` |
| **Model size** | 2.2 GB | 2.2 GB | 4.1 GB | 4.1 GB |
| **Quantization** | Q4_0 (GGUF) | Q4_0 (GGUF) | Q4_0 (GGUF) | int4 (.task) |
| **APK size** | 57 MB | 58 MB | 58 MB | 164 MB |
| **Backend** | CPU only | CPU only | CPU only | CPU (GPU available) |
| **Model load** | 5.0 s | 3.4 s | 13.5 s | 1.2 s |
| **Prefill** | 50.0 s (413 tok, 8.3 t/s) | 45.3 s (413 tok, 9.1 t/s) | 62.7 s (414 tok, 6.6 t/s) | 16.4 s (TTFT) |
| **Decode** | 18.2 s (78 tok, 4.3 t/s) | 3.8 s (18 tok, 4.7 t/s) | 40.0 s (141 tok, 3.5 t/s) | 19.8 s (~103 tok, ~5.2 t/s) |
| **Total query** | 68.2 s | 49.2 s | 102.7 s | 36.2 s |
| **Response** | 405 chars | 79 chars | 706 chars | 411 chars |

## Key Findings

### 1. llama.cpp b8157 upgrade improves performance

Upgrading from b5220 to b8157 improved MedGemma 4B performance:
- Model load: 5.0s → 3.4s (32% faster)
- Prefill: 50.0s → 45.3s (10% faster)
- Decode throughput: 4.3 → 4.7 t/s (9% faster)

### 2. Gemma 3n now works on llama.cpp (b8157)

Previously failed on b5220 (no `gemma3n` architecture support). Gemma 3n support was added in [PR #14400](https://github.com/ggml-org/llama.cpp/pull/14400) (merged June 2025, minimum version b5769).

### 3. Gemma 3n is much slower on llama.cpp than MediaPipe

Same model (Gemma 3n E4B), same device:
- **llama.cpp**: 102.7s total (62.7s prefill + 40.0s decode at 3.5 t/s)
- **MediaPipe**: 36.2s total (16.4s prefill + 19.8s decode at ~5.2 t/s)

MediaPipe is **2.8x faster** for the same model. Google has optimized MediaPipe specifically for Tensor chips; llama.cpp's CPU backend is generic.

### 4. MediaPipe prefill is 3-4x faster than llama.cpp

MediaPipe prefill (TTFT): **16.4s**. llama.cpp prefill: 45-63s depending on model. MediaPipe's `addQueryChunk()` returns in 6ms (lazy queuing), with actual prefill happening during generation start.

### 5. Thermal throttling compounds Gemma 3n on llama.cpp

The Pixel 7's Tensor G2 throttles aggressively under sustained CPU load. Gemma 3n's 62.7s prefill on llama.cpp causes severe throttling before decode begins, further slowing generation (3.5 t/s vs 4.7 t/s for MedGemma which has shorter prefill).

### 6. MedGemma 4B on llama.cpp is competitive with MediaPipe

With b8157, MedGemma on llama.cpp (49.2s) is only 1.4x slower than Gemma 3n on MediaPipe (36.2s). However, MedGemma has a 45s blank screen (synchronous prefill) vs MediaPipe's 16s — worse user experience.

## Observations

**Advantages of llama.cpp**:
- Can run any GGUF model (model flexibility)
- MedGemma 4B may produce better medical answers than Gemma 3n (not evaluated here)
- Smaller APK (58 MB vs 164 MB — no bundled MediaPipe native libs)
- Upgrading to b8157 enables Gemma 3n and improves performance

**Advantages of MediaPipe**:
- 3-4x faster prefill (16.4s vs 45-63s)
- Faster total query time (36.2s vs 49-103s)
- Faster model load (1.2s vs 3.4-13.5s)
- Higher decode throughput (~5.2 t/s vs 3.5-4.7 t/s)
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

Note: MedGemma 4B on b8157 produced a short response (18 tokens / 79 chars) — it hit EOS early. Decode throughput (4.7 t/s) is comparable to b5220 (4.3 t/s).

## Recommendation

**Stick with MediaPipe + Gemma 3n** for production. It is the fastest option across all metrics (load, prefill, decode, total).

Consider llama.cpp + MedGemma if:
- MedGemma's medical accuracy is significantly better than Gemma 3n (requires separate quality evaluation)
- The 45s blank-screen prefill can be mitigated (prompt caching, shorter system prompts)
- APK size is a priority (58 MB vs 164 MB)

Do **not** use Gemma 3n on llama.cpp — it is 2.8x slower than the same model on MediaPipe.
