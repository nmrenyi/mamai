# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MAM-AI is a medical search application for nurses and midwives in Zanzibar. It uses on-device RAG (Retrieval-Augmented Generation) with the Gemma 3n model to provide medical information searches without requiring internet connectivity. The app runs LLM inference entirely on-device using Google AI Edge MediaPipe.

## Repository Structure

- **`app/`**: Flutter application with Android backend
  - Flutter frontend in `app/lib/`
  - Android native code in `app/android/app/src/main/kotlin/com/example/app/`
- **`rag/`**: Python scripts for document preprocessing and chunking
- **`finetune/`**: Python scripts for Gemma 3n model finetuning (not currently deployed in app)

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

**Note**: The app requires real Android hardware (not emulators) because the MediaPipe inference library needs actual hardware acceleration.

### Python Components

For RAG document processing (`rag/`):
```bash
cd rag
pip install -r requirements.txt.txt
python rag.py
```

For model finetuning (`finetune/`):
```bash
cd finetune
python3.10 -m venv .venv
source .venv/bin/activate  # or .venv\Scripts\activate on Windows
pip install -r requirements.txt
python main_training.py
```

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

1. **LLM Backend**: MediaPipe-based Gemma 3n inference
   - Model: `gemma-3n-E4B-it-int4.task` (int4 quantized)
   - Runs on CPU (`LlmInference.Backend.CPU`)
   - Max tokens: 4096

2. **Embeddings**: Gecko embedding model for semantic search
   - Model: `Gecko_1024_quant.tflite` (768-dim embeddings)
   - Tokenizer: `sentencepiece.model`
   - Runs on CPU (`USE_GPU_FOR_EMBEDDINGS = false`)

3. **Vector Store**: SQLite-backed semantic memory
   - Database: `embeddings.sqlite` (pre-computed document embeddings)
   - Retrieval: Top-3 documents via cosine similarity

**Initialization**: Heavy initialization happens lazily and asynchronously. Models are loaded on first access and signal readiness via a rendezvous channel (`onLlmReady`).

**Query flow**:
1. User submits prompt in Flutter UI
2. Android embeds the query and searches vector store for top-3 relevant documents
3. Documents + query are fed to Gemma 3n with the prompt template
4. LLM generates streaming response sent back to Flutter via EventChannel

### Streaming Architecture

- **`RagStream.kt`**: Manages the event channel stream and job lifecycle
  - Prevents duplicate queries for the same prompt
  - Cancels previous jobs when new queries arrive
  - Marshals async generation callbacks back to UI thread for Flutter communication

### Model Files

Models are fetched from a remote server on first launch and stored in `application.getExternalFilesDir(null)`:
- `gemma-3n-E4B-it-int4.task`: Gemma 3n LLM (int4 quantized)
- `Gecko_1024_quant.tflite`: Gecko embedding model
- `sentencepiece.model`: Tokenizer
- `embeddings.sqlite`: Pre-computed document embeddings

### Document Ingestion (RAG preprocessing)

Documents are chunked and embedded offline using scripts in `rag/`:

1. Extract text from PDFs using [MMORE](https://github.com/swiss-ai/mmore)
2. Chunk documents with separator tags (`<sep>`, `<doc_sep>`)
3. Embed chunks using Gecko model
4. Store in SQLite vector database

**To add new documents**:
1. Add chunks to `app/assets/mamai_trim.txt`
2. Uncomment `memorizeChunks()` call in `RagPipeline.kt:103`
3. Run app (waits while chunks are embedded and stored)
4. Re-comment `memorizeChunks()`
5. Use `adb` to pull updated `embeddings.sqlite` from device

## Key Configuration

### Prompt Template

The RAG prompt is defined in `RagPipeline.kt:205-225`. It emphasizes:
- Medical accuracy and safety
- Simple language for second-language speakers
- Conciseness and bullet points
- Emergency escalation when appropriate
- Single-shot responses (no multi-turn conversations)

### Backend Selection

Both LLM and embeddings use **CPU backend** (not GPU). Change in `RagPipeline.kt`:
- Line 41: `setPreferredBackend(LlmInference.Backend.CPU)`
- Line 197: `USE_GPU_FOR_EMBEDDINGS = false`

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

**Critical**: MediaPipe LLM backend crashes if multiple queries run concurrently. `RagStream` enforces single-query execution:
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

The app downloads models from a temporary VPS on first launch. Files are hosted via nginx with self-signed cert (`cert.pem` bundled in assets for TLS verification).

To use your own model hosting:
1. Update download URLs in the Flutter code
2. Replace `app/cert.pem` with your server's certificate
3. Host the four model files (listed in "Model Files" section above)
