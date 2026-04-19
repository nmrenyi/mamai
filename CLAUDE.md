# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Priority

**Evaluation quality and response safety are the top priorities in this project, above all other concerns** (performance, code hygiene, new features, etc.).

This is a medical app used by nurses and midwives in Zanzibar. Wrong or unsafe medical advice has direct patient harm consequences. When triaging work or making any technical decision, always ask: *does this help ensure the model is accurate and safe?*

- Safety judge scores of 1 (the lowest rating) must always be flagged and addressed before other work.
- Deployment decisions (model selection, RAG config) must be driven by eval results, especially on clinical datasets (e.g. `kenya_vignettes`).
- RAG regressions — where retrieval context hurts model accuracy — are a patient safety concern, not just a benchmarking curiosity.

## Project Overview

MAM-AI is a medical search application for nurses and midwives in Zanzibar. It uses on-device RAG (Retrieval-Augmented Generation) with the Gemma 4 E4B model to provide medical information searches without requiring internet connectivity. The app runs LLM inference entirely on-device using Google AI Edge LiteRT-LM.

## Repository Structure

- **`app/`**: Flutter application with Android backend
  - Flutter frontend in `app/lib/`
  - Android native code in `app/android/app/src/main/kotlin/com/example/app/`
- **`evaluation/`**: Evaluation harness, cluster scripts, and reports
- **`scripts/`**: Dev tooling — RAG asset sync, model download, device push
- **`config/`**: Shared runtime config and system prompts

## Building and Running

### Flutter App

From the `app/` directory:

```bash
# Get dependencies
flutter pub get

# Build APK for Android
flutter build apk

# Run on connected device/emulator
flutter run

# Run with verbose logging
flutter run -v
```

**Note**: The app requires real Android hardware (not emulators) because LiteRT-LM needs actual hardware acceleration.

## Release Tag Policy

- Use `vX.Y.Z` for stable releases
- Use `vX.Y.Z-alpha.N`, `vX.Y.Z-beta.N`, or `vX.Y.Z-rc.N` for staged releases
- Tag from `main` only
- Never move or reuse a published tag

## Architecture

### Flutter <-> Android Communication

The app uses Flutter platform channels for bidirectional communication:

- **Method Channel** (`io.github.mzsfighters.mam_ai/request_generation`): Flutter calls into Android
  - `ensureInit`: Trigger/wait for LLM initialization
  - `generateResponse(String prompt)`: Request a search query response

- **Event Channel** (`io.github.mzsfighters.mam_ai/latest_message`): Android streams back to Flutter
  - Sends retrieval results (documents found via vector search)
  - Sends generation output (streaming LLM response as it's generated)

**Key files**:
- `app/lib/screens/search_page.dart`: Flutter side of channel communication
- `app/android/app/src/main/kotlin/com/example/app/MainActivity.kt`: Android side channel setup

### Android RAG Pipeline

The RAG pipeline (`RagPipeline.kt`) manages three main components:

1. **LLM Backend**: LiteRT-LM Gemma 4 E4B inference
   - Model: `gemma-4-E4B-it.litertlm` (int4 quantized, 3.65 GB)
   - CPU by default; GPU opt-in via `useGpuForLlm` Gradle property (see Backend Selection)
   - Max tokens: 4096

2. **Embeddings**: Gecko embedding model for semantic search
   - Model: `Gecko_1024_quant.tflite` (768-dim embeddings)
   - Tokenizer: `sentencepiece.model`
   - CPU by default (`use_gpu_for_embeddings: false` in `app_config.json`)

3. **Vector Store**: SQLite-backed semantic memory
   - Database: `embeddings.sqlite` (pre-computed document embeddings)
   - Retrieval: Top-3 documents via cosine similarity

**Initialization**: Heavy initialization happens lazily and asynchronously. Models are loaded on first access and callers wait via `awaitLlmReady()`, which propagates init failures instead of silently unblocking.

**Query flow**:
1. User submits prompt in Flutter UI
2. Android embeds the query and searches vector store for top-3 relevant documents
3. Documents + query are fed to Gemma 4 E4B with the prompt template
4. LiteRT-LM generates a streaming response sent back to Flutter via EventChannel

### Streaming Architecture

- **`RagStream.kt`**: Manages the event channel stream and job lifecycle
  - Prevents duplicate queries for the same prompt
  - Cancels previous jobs when new queries arrive
  - Marshals async generation callbacks back to UI thread for Flutter communication

### Model Files

Models are downloaded on first launch from HuggingFace and stored in `application.getExternalFilesDir(null)`:
- `gemma-4-E4B-it.litertlm`: Gemma 4 E4B LLM (int4 quantized, 3.65 GB) — `litert-community/gemma-4-E4B-it-litert-lm`
- `Gecko_1024_quant.tflite`: Gecko embedding model — `litert-community/Gecko-110m-en`
- `sentencepiece.model`: Tokenizer — `litert-community/Gecko-110m-en`
- `embeddings.sqlite`: Pre-computed document embeddings — mamai-medical-guidelines GitHub release

Model download URLs are defined in `_modelFileUrls` in `app/lib/screens/intro_page.dart`. The pinned RAG bundle URL/version live in `config/rag_assets.lock.json`.

### Document Ingestion (RAG preprocessing)

Chunking and embedding are managed in the companion `mamai-medical-guidelines` repo.
This repo only consumes the published output via a versioned bundle.

**To update RAG assets** (new guidelines or re-chunking):
1. Run the producer pipeline in `mamai-medical-guidelines` and publish a new bundle
2. Bump `config/rag_assets.lock.json` in this repo with the new version + manifest checksum
3. Run `bash scripts/sync_rag_assets.sh` to install the bundle into `device_push/`
4. Push to device (see `device_push/README.md`)

`memorizeChunks()` in `RagPipeline.kt` is intentionally commented out — embeddings
are pre-computed in the producer repo and shipped as `embeddings.sqlite`, not
generated on-device.

## Key Configuration

### Prompt Template

The RAG prompt is defined in `RagPipeline.kt:205-225`. It emphasizes:
- Medical accuracy and safety
- Simple language for second-language speakers
- Conciseness and bullet points
- Emergency escalation when appropriate
- Single-shot responses (no multi-turn conversations)

### Backend Selection

- **LLM**: defaults to CPU in production. Controlled by the `USE_GPU_FOR_LLM` `BuildConfig` field, set at compile time via the Gradle property `useGpuForLlm` (default `false`). If GPU init fails at runtime, `RagPipeline.kt` automatically falls back to CPU.
- **Embeddings**: CPU by default (`use_gpu_for_embeddings: false` in `config/app_config.json`).

**To enable GPU locally** (e.g. for latency testing on a capable device), add to `~/.gradle/gradle.properties`:
```
useGpuForLlm=true
```
Or pass it at build time: `flutter build apk -PuseGpuForLlm=true`. Do not commit this flag — production APKs ship with CPU by default until GPU support is validated across target devices.

### Retrieval Parameters

Configured in `RagPipeline.kt:181-183`:
- Number of retrieved documents: 3
- Similarity threshold: 0.0 (no filtering)
- Task type: `RETRIEVAL_QUERY`

## Development Notes

### Performance Logging

The codebase includes extensive timing and memory logs with tag `"mam-ai"`:
- Model initialization time
- Query embedding time
- Vector search time
- Generation time
- Heap memory usage

Use `adb logcat -s mam-ai` to monitor performance.

### Flutter Dependencies

Key packages:
- `flutter_native_splash`: Splash screen handling
- `markdown_widget`: Render LLM responses as markdown
- `dio`: HTTP client for downloading model files
- `path_provider`: Access device storage directories
- `url_launcher`: Open external links

### Threading Model

- RAG pipeline initialization happens on the main thread (blocking)
- LLM `initialize()` call is async (runs on executor)
- Query processing happens on background executor (`Executors.newSingleThreadExecutor()`)
- Event channel callbacks are marshaled back to UI thread via `Handler(Looper.getMainLooper()).post()`

### Concurrency Constraints

**Critical**: LiteRT-LM crashes if multiple queries run concurrently. `RagStream` enforces single-query execution:
- Cancels previous job when new query arrives
- Prevents duplicate queries for identical prompts
- Uses synchronized blocks to protect job state

## Testing

No automated tests are currently present in the repository. To test the app:

1. Build and install APK on real Android device
2. Wait for model download and initialization (~30-60 seconds on first launch)
3. Submit test queries using suggestion chips or search bar
4. Verify:
   - Retrieved documents appear
   - LLM generates relevant response
   - Response streams incrementally (not all at once)
   - Check logcat for performance metrics

## Remote Resources

All model files are downloaded from public HuggingFace repos on first launch — no auth required. Update model URLs in `_modelFileUrls` in `app/lib/screens/intro_page.dart`. Update the pinned RAG bundle release in `config/rag_assets.lock.json`.
