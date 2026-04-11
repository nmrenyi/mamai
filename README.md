# MAM-AI

<p align="center">
  <img src="app/images/logo.png" alt="MAM-AI Logo" width="180"/>
</p>

<p align="center">
  <strong>On-device medical search for nurses and midwives in Zanzibar</strong>
</p>

<p align="center">
  <a href="https://youtu.be/M_Kruluel28">Demo Video</a> · <a href="https://www.kaggle.com/competitions/google-gemma-3n-hackathon">Gemma 3n Kaggle Challenge</a> · <a href="evaluation/reports/eval_report_no_rag.md">Eval Report</a> · <a href="evaluation/reports/latency_report.md">Latency Report</a>
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
│   └── text_extraction_json.py      # JSONL text extraction utility
├── finetune/               # Gemma finetuning (Python, not deployed in app)
│   ├── main_training.py             # Training entry point
│   ├── config.py                    # Hyperparameters & paths
│   ├── model_setup.py               # LoRA + quantization setup
│   ├── data_processing.py           # QA dataset formatting
│   └── training.py                  # SFTTrainer wrapper
├── evaluation/             # Model quality & latency benchmarking
│   ├── cluster/                     # RunAI cluster job scripts
│   ├── reports/                     # Final evaluation reports
│   ├── run_eval.py                  # Main evaluation harness
│   ├── scoring.py                   # LLM-as-judge scoring
│   └── benchmark_latency.py         # On-device latency analysis
├── device_push/            # Staging area for adb push to device
│   ├── docs/                        # Source PDF guidelines (gitignored)
│   └── models/                      # Gecko TFLite, embeddings, tokenizer (gitignored)
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

Chunking and embedding are managed in the companion
[mamai-medical-guidelines](https://github.com/TODO_ORG/mamai-medical-guidelines) repo,
which publishes versioned bundles containing `embeddings.sqlite` and the 55 source PDFs.

To update the RAG assets in this repo, bump `rag-assets.lock.json` and run:

```bash
# Install from a local bundle (development):
bash scripts/sync_rag_assets.sh --local /path/to/rag-bundle-<version>/

# Install from a published GitHub release:
bash scripts/sync_rag_assets.sh
```

Then push to device (see `device_push/README.md`).

**Producer pipeline** (in `mamai-medical-guidelines`):
1. Curate PDFs → extract to markdown → chunk → embed (Gecko TFLite on cluster)
2. `python scripts/package_bundle.py --version vX.Y.Z`
3. Publish bundle as a GitHub release
4. Update `rag-assets.lock.json` here with the new version + manifest checksum

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

### Answering Accuracy

We evaluate model accuracy across multiple medical QA benchmarks, including MCQ datasets (AfriMedQA, MedQA USMLE, MedMCQA) and open-ended clinical vignettes (Kenya Vignettes, AfriMedQA SAQ, WHB Stumps). Open-ended responses are scored by an LLM judge on accuracy, safety, completeness, helpfulness, and clarity.

- **Best overall model**: GPT-5 at **80.9%** average MCQ accuracy and **4.47/5** average open-ended judge score
- **Best fully evaluated on-device model**: Gemma 3n E4B at **45.6%** MCQ and **3.06/5** open-ended
- **Current deployed model check**: Gemma 4 E4B reaches **42.9%** average MCQ accuracy and **2.94/5** open-ended (no RAG), which is below Gemma 3n E4B on both MCQ (**45.6%**) and open-ended (**3.06/5**)
- **RAG currently hurts MCQ performance** for all evaluated on-device models, with Gemma 3n E4B dropping from **45.6% → 43.4%**
- **Gemma 4 E4B +RAG evaluation is still pending**

See [evaluation/reports/eval_report_no_rag.md](evaluation/reports/eval_report_no_rag.md) for the full benchmark tables.

### Latency

We benchmark on-device latency on real Android hardware, measuring time-to-first-token (TTFT), decode throughput (tokens/sec), and end-to-end query time across short, medium, and long clinical queries.

- On an OPPO Snapdragon 8 Elite device, **LiteRT-LM + Gemma 4 E4B** averages **11.7 s TTFT**, **26.8 s total time**, and **13.8 tok/s**
- On the same device, **LiteRT-LM + Gemma 3n E4B** is still faster for user-perceived latency at **6.8 s TTFT** and **24.8 s total time**
- The current conclusion is that **Gemma 4 E4B is not yet a clear CPU-only upgrade**: decode is faster, but TTFT is worse and MCQ accuracy is lower
- GPU evaluation remains blocked on a LiteRT-LM Android release with working GPU decode for E4B

See [evaluation/reports/benchmark_report.md](evaluation/reports/benchmark_report.md) and [evaluation/reports/latency_report.md](evaluation/reports/latency_report.md) for details.

### Stability

We evaluate response consistency under repeated identical queries and across varying conversation history lengths, assessing whether the model produces reliable outputs under the constraints of on-device inference.

A dedicated stability benchmark has not yet been published as a separate report. The app already includes single-query execution, cancellation, background-generation handling, and history truncation to fit the context window, but response-consistency numbers are still pending.

### Dangerous Scenario Recognition

A dedicated evaluation of how the app handles high-stakes clinical emergencies — including postpartum hemorrhage, eclampsia, neonatal respiratory distress, and sepsis. We assess whether the model correctly identifies emergency escalation triggers, avoids underreacting to critical presentations, and produces safe, actionable guidance aligned with MOHSW Zanzibar protocols.

This has not yet been isolated as a standalone benchmark. For now, the closest signal is the open-ended judge scoring in [evaluation/reports/eval_report_no_rag.md](evaluation/reports/eval_report_no_rag.md), where on-device models trail GPT-5 most sharply on **accuracy** and **safety**.

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
