# MAM-AI

<p align="center">
  <img src="app/images/logo.png" alt="MAM-AI Logo" width="180"/>
</p>

<p align="center">
  <strong>On-device medical search for nurses and midwives in Zanzibar</strong>
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=DbioClzbEKs">Demo Video</a> · <a href="https://www.kaggle.com/competitions/google-gemma-3n-hackathon">Gemma 3n Kaggle Challenge</a> · <a href="evaluation/EVAL_REPORT.md">Eval Report</a> · <a href="evaluation/LATENCY_REPORT.md">Latency Report</a>
</p>

---

MAM-AI is an Android application that provides medical information search for maternal and neonatal healthcare workers. It runs entirely on-device using **Gemma 3n** via Google AI Edge MediaPipe — no internet connection is needed after the initial model download. Users type clinical questions in natural language and receive guideline-grounded answers powered by on-device RAG (Retrieval-Augmented Generation).

## Key Features

- **Fully offline** — LLM inference, embedding, and vector search all run on the phone
- **On-device RAG** — retrieves relevant passages from 2,826 pre-embedded medical guideline chunks via Gecko embeddings + SQLite cosine similarity
- **Streaming responses** — answers appear token-by-token as they are generated
- **Conversation history** — multi-turn conversations with persistent storage
- **Medical safety focus** — prompt template emphasizes accuracy, simple language for second-language speakers, and emergency escalation
- **Gemma 3n E4B** — 4.1 GB int4-quantized model, ~90s median query time on a Pixel 7

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Flutter UI (Dart)                              │
│  intro_page.dart · search_page.dart             │
│  conversation_store.dart                        │
├──────────────┬──────────────────────────────────┤
│ MethodChannel│  EventChannel (streaming)        │
├──────────────┴──────────────────────────────────┤
│  Android Native (Kotlin)                        │
│  MainActivity.kt · RagStream.kt                 │
│  ┌────────────────────────────────────────────┐ │
│  │ RagPipeline.kt                             │ │
│  │  ┌──────────┐ ┌──────────┐ ┌────────────┐ │ │
│  │  │ Gemma 3n │ │  Gecko   │ │  SQLite    │ │ │
│  │  │ MediaPipe│ │ Embedder │ │ VectorStore│ │ │
│  │  └──────────┘ └──────────┘ └────────────┘ │ │
│  └────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

**Query flow:**
1. User types a clinical question in the Flutter chat UI
2. Query is sent to Android via platform MethodChannel
3. Gecko embeds the query → SQLite cosine similarity retrieves top-3 guideline chunks
4. Retrieved context + query + conversation history are assembled into a Gemma IT prompt
5. MediaPipe LLM generates a streaming response, sent back via EventChannel
6. Flutter renders the response as markdown in real time

## Install

Download the APK from the [GitHub Releases](../../releases) tab and install it on a real Android device. Emulators may not work — MediaPipe requires actual hardware acceleration.

On first launch, the app downloads ~4.5 GB of model files (LLM, embeddings model, tokenizer, vector database). After that, it works fully offline.

## Repository Structure

```
mamai/
├── app/                    # Flutter + Android application
│   ├── lib/                #   Flutter frontend (Dart)
│   │   ├── main.dart
│   │   ├── screens/
│   │   │   ├── intro_page.dart      # License acceptance & model download
│   │   │   └── search_page.dart     # Main chat interface
│   │   └── conversation_store.dart  # Conversation persistence
│   ├── android/app/src/main/kotlin/com/example/app/
│   │   ├── MainActivity.kt          # Flutter ↔ Android channel bridge
│   │   ├── RagPipeline.kt           # Core RAG engine (LLM + embeddings + vector store)
│   │   ├── RagStream.kt             # Streaming & concurrency control
│   │   ├── BenchmarkActivity.kt     # Headless latency benchmarking
│   │   └── BenchmarkQueries.kt      # Predefined test queries
│   └── pubspec.yaml
├── rag/                    # Document preprocessing & chunking (Python)
│   ├── rag.py                       # Chunking, embedding, and RAG evaluation
│   ├── chunks_testing.py            # Chunk analysis utilities
│   └── text_extraction_json.py      # JSONL text extraction
├── finetune/               # Gemma 3n finetuning (Python, not deployed in app)
│   ├── main_training.py             # Training entry point
│   ├── config.py                    # Hyperparameters & paths
│   ├── model_setup.py               # LoRA + quantization setup
│   ├── data_processing.py           # QA dataset formatting
│   └── training.py                  # SFTTrainer wrapper
├── evaluation/             # Model quality & latency benchmarking
│   ├── run_eval.py                  # Main evaluation harness
│   ├── scoring.py                   # LLM-as-judge scoring
│   ├── benchmark_latency.py         # On-device latency analysis
│   ├── EVAL_REPORT.md               # Quality results (5 models × 6 datasets)
│   └── LATENCY_REPORT.md            # On-device latency results
└── CLAUDE.md               # Developer instructions for Claude Code
```

## Building from Source

### Prerequisites

- Flutter SDK ≥ 3.8.1
- Android SDK 24+ with NDK 27.0
- A real Android device (not an emulator)

### Build & Run

```bash
cd app
flutter pub get
flutter build apk        # Build release APK
flutter run               # Run on connected device
```

### Monitor Performance

```bash
adb logcat -s mam-ai      # View timing, memory, and inference logs
```

## RAG Document Pipeline

The offline document ingestion process:

1. Curate medical guideline PDFs
2. Extract text using [MMORE](https://github.com/swiss-ai/mmore)
3. Chunk documents using the scripts in `rag/`
4. Copy chunks to `app/assets/mamai_trim.txt`
5. Uncomment `memorizeChunks()` in `RagPipeline.kt`, run the app (embeds chunks into SQLite)
6. Re-comment `memorizeChunks()` and pull `embeddings.sqlite` from the device with `adb`

```bash
cd rag
pip install -r requirements.txt.txt
python rag.py
```

## Model Files

Downloaded on first launch from a temporary VPS and stored on-device:

| File | Description | Source |
|---|---|---|
| `gemma-3n-E4B-it-int4.task` | Gemma 3n E4B LLM (int4 quantized, 4.1 GB) | [Google](https://ai.google.dev/gemma) |
| `Gecko_1024_quant.tflite` | Gecko embedding model (768-dim) | [litert-community/Gecko-110m-en](https://huggingface.co/litert-community/Gecko-110m-en) |
| `sentencepiece.model` | Gecko tokenizer | [litert-community/Gecko-110m-en](https://huggingface.co/litert-community/Gecko-110m-en) |
| `embeddings.sqlite` | Pre-computed embeddings for 2,826 guideline chunks | Generated via `rag/` pipeline |

> **Note:** Gemma requires license acceptance before use. The temporary VPS hosting these files will only remain up during the Kaggle challenge judging period. To self-host, update the download URLs in `intro_page.dart` and replace `app/cert.pem` with your server's TLS certificate.

## Evaluation

We evaluated 5 models across 6 medical QA benchmarks (3 MCQ, 3 open-ended). See the full reports:

- [**Eval Report**](evaluation/EVAL_REPORT.md) — quality benchmarks
- [**Latency Report**](evaluation/LATENCY_REPORT.md) — on-device performance

### Quality Summary

| Model | MCQ Avg | Open-ended Avg (/5) |
|---|:---:|:---:|
| GPT-5 (cloud baseline) | **80.9%** | **4.47** |
| Gemma 3n E4B (deployed) | 45.6% | 3.06 |
| MedGemma 4B | 44.5% | 2.90 |
| Meditron3 8B | 41.0% | 2.88 |
| Gemma 3n E2B | 41.4% | 2.76 |

**Gemma 3n E4B** is the best on-device model across both MCQ accuracy and open-ended quality. Medical-domain finetuned models (MedGemma, Meditron3) did not consistently outperform it at this quantization level.

### Latency Summary (Pixel 7)

| Metric | E4B | E2B |
|---|---|---|
| Median query time | **91s** | 205s |
| Decode throughput | **3.3 tok/s** | 1.4 tok/s |
| Model load (warm) | ~1.2s | ~1.1s |

E4B delivers consistent performance regardless of query length, while E2B degrades dramatically on medium/long queries.

## Finetuning

We finetuned Gemma 3n E4B on medical QA data using LoRA (not yet deployed in the app).

- [Finetuning Dataset](https://drive.google.com/drive/folders/1vdheVGdrOTXwekaIrSkve7JF28Tpq1Xf?usp=sharing)
- [Finetuned Model](https://huggingface.co/fiifidawson/mam-ai-gemma-3n-medical-finetuned)

```bash
cd finetune
python3.10 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python main_training.py
```

## Self-Hosting Model Files

To serve the model files from your own server:

1. Host the four model files behind nginx (or any HTTPS server)
2. Update the download URLs in `app/lib/screens/intro_page.dart`
3. Replace `app/cert.pem` with your server's TLS certificate
4. Rebuild the APK

## License

This project is licensed under [CC BY 4.0](LICENSE).
