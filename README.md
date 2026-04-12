# MAM-AI

<p align="center">
  <img src="app/images/logo.png" alt="MAM-AI Logo" width="180"/>
</p>

<p align="center">
  <strong>On-device medical search for nurses and midwives in Zanzibar</strong>
</p>

<p align="center">
  <a href="https://youtu.be/M_Kruluel28">Demo Video</a> · <a href="https://www.kaggle.com/competitions/google-gemma-3n-hackathon">Gemma 3n Kaggle Challenge</a> · <a href="evaluation/reports/eval_report_app_parity_v1.md">Eval Report</a> · <a href="evaluation/reports/latency_report.md">Latency Report</a>
</p>

---

MAM-AI is an Android application that provides medical information search for maternal and neonatal healthcare workers. It runs entirely on-device using **Gemma 4 E4B** via Google AI Edge LiteRT-LM — no internet connection is needed after the initial model download. Users type clinical questions in natural language and receive guideline-grounded answers powered by on-device RAG (Retrieval-Augmented Generation).

## Key Features

- **Fully offline** — LLM inference, embedding, and vector search all run on the phone
- **On-device RAG** — retrieves relevant passages from 2,826 pre-embedded medical guideline chunks via Gecko embeddings + SQLite cosine similarity
- **Streaming responses** — answers appear token-by-token as they are generated
- **Conversation history** — multi-turn conversations with persistent storage
- **Medical safety focus** — prompt template emphasizes accuracy, simple language for second-language speakers, and emergency escalation
- **Gemma 4 E4B** — 3.65 GB int4-quantized LiteRT-LM model deployed on-device

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
│  │  │ Gemma 4  │ │  Gecko   │ │  SQLite    │ │ │
│  │  │ LiteRT-LM│ │ Embedder │ │ VectorStore│ │ │
│  │  └──────────┘ └──────────┘ └────────────┘ │ │
│  └────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

**Query flow:**
1. User types a clinical question in the Flutter chat UI
2. Query is sent to Android via platform MethodChannel
3. Gecko embeds the query → SQLite cosine similarity retrieves top-3 guideline chunks
4. Retrieved context + query + conversation history are assembled into a Gemma IT prompt
5. LiteRT-LM generates a streaming response, sent back via EventChannel
6. Flutter renders the response as markdown in real time

## Install

Download the APK from the [GitHub Releases](../../releases) tab and install it on a real Android device. Emulators are not a supported target for the on-device LiteRT-LM stack.

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
├── evaluation/             # Model quality & latency benchmarking
│   ├── cluster/                     # RunAI cluster job scripts
│   ├── reports/                     # Final evaluation reports
│   ├── run_eval.py                  # Main evaluation harness
│   ├── scoring.py                   # LLM-as-judge scoring
│   └── benchmark_latency.py         # On-device latency analysis
├── device_push/            # Staging area for adb push to device
│   ├── bundle/                      # Staged RAG assets for device sync
│   │   ├── docs/                    # Source PDF guidelines (gitignored)
│   │   └── embeddings.sqlite        # SQLite embeddings store (gitignored)
│   └── models/                      # Gecko TFLite, tokenizer, optional LLMs (gitignored)
└── CLAUDE.md               # Developer instructions for Claude Code
```

## Project Tracking

Work tracking lives in [GitHub Issues](https://github.com/nmrenyi/mamai/issues). This repo does not maintain a separate local `TODO.md`.

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
[mamai-medical-guidelines](https://github.com/nmrenyi/mamai-medical-guidelines) repo,
which publishes versioned bundles containing `embeddings.sqlite` and the 55 source PDFs.

To update the RAG assets in this repo, bump `config/rag_assets.lock.json` and run:

```bash
# Sync the pinned GitHub release into the local cache + device_push/
bash scripts/sync_rag_assets.sh

# Optional: use aria2c for faster download/progress output
bash scripts/sync_rag_assets.sh --aria2c

# Download Gemma 4 + Gecko model files from HuggingFace into device_push/models/
bash scripts/sync_models.sh

# Push the staged bundle to a connected Android device
bash scripts/push_to_device.sh

# Push Gecko + sentencepiece.model (and optionally Gemma)
bash scripts/push_to_device.sh --models
```

`sync_rag_assets.sh` keeps a local bundle cache in `_scratch/rag_bundle_cache/`
and rebuilds the single active staged view in `device_push/`. By default it
prefers `gh release download` for GitHub asset correctness; `--aria2c` is an
explicit speed/progress override. The checked push script verifies that the
staged bundle still matches `config/rag_assets.lock.json` before copying files to the
device, then writes `rag_bundle_deployed.json` on the device only after a full
successful push. See `device_push/README.md` for details.

**Producer pipeline** (in `mamai-medical-guidelines`):
1. Curate PDFs → extract to markdown → chunk → embed (Gecko TFLite on cluster)
2. `python scripts/package_bundle.py --version vX.Y.Z`
3. Publish bundle as a GitHub release
4. Update `config/rag_assets.lock.json` here with the new version + manifest checksum

## Model Files

Downloaded on first launch and stored on-device. All files are fetched directly from public HuggingFace repos — no authentication required.

| File | Description | Source |
|---|---|---|
| `gemma-4-E4B-it.litertlm` | Gemma 4 E4B LLM (int4 quantized, 3.65 GB) | [litert-community/gemma-4-E4B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) |
| `Gecko_1024_quant.tflite` | Gecko embedding model (768-dim, 146 MB) | [litert-community/Gecko-110m-en](https://huggingface.co/litert-community/Gecko-110m-en) |
| `sentencepiece.model` | Gecko tokenizer (794 KB) | [litert-community/Gecko-110m-en](https://huggingface.co/litert-community/Gecko-110m-en) |
| `embeddings.sqlite` | Pre-computed embeddings for guideline chunks | [mamai-medical-guidelines releases](https://github.com/nmrenyi/mamai-medical-guidelines/releases) |

> **Note:** Gemma requires license acceptance before use. The app presents the license dialog before downloading. The pinned RAG bundle URL/version now live in `config/rag_assets.lock.json`, which is shared by the app and the staging scripts.

## Evaluation

### Answering Accuracy

We evaluate model accuracy across multiple medical QA benchmarks, including MCQ datasets (AfriMedQA, MedQA USMLE, MedMCQA) and open-ended clinical vignettes (Kenya Vignettes, AfriMedQA SAQ, WHB Stumps). Open-ended responses are scored by an LLM judge on accuracy, safety, completeness, helpfulness, and clarity.

- **Best overall model**: GPT-5 at **82.8%** average MCQ accuracy and **4.19/5** average open-ended judge score (no-RAG)
- **Best on-device model**: Gemma 3n E4B at **45.5%** average MCQ and **2.98/5** open-ended (no-RAG)
- **Current deployed model**: Gemma 4 E4B at **42.9%** average MCQ and **2.61/5** open-ended (no-RAG) — below Gemma 3n E4B on both metrics
- **RAG hurts on-device models**: Gemma 4 E4B drops from **42.9% → 43.4%** average MCQ under RAG; Gemma 3n E4B drops from **45.5% → 43.4%**; GPT-5 is largely unaffected
- All three models fully evaluated under the `app_parity_v1` protocol (unified config, same system prompt as APK, versioned RAG contexts)

See [evaluation/reports/eval_report_app_parity_v1.md](evaluation/reports/eval_report_app_parity_v1.md) for the full benchmark tables.

### Latency

We benchmark on-device latency on real Android hardware, measuring time-to-first-token (TTFT), decode throughput (tokens/sec), and end-to-end query time across short, medium, and long clinical queries.

- On an OPPO Snapdragon 8 Elite device, **LiteRT-LM + Gemma 4 E4B** averages **11.7 s TTFT**, **26.8 s total time**, and **13.8 tok/s**
- On the same device, **LiteRT-LM + Gemma 3n E4B** is still faster for user-perceived latency at **6.8 s TTFT** and **24.8 s total time**
- The current conclusion is that **Gemma 4 E4B is not yet a clear CPU-only upgrade**: decode is faster, but TTFT is worse and MCQ accuracy is lower
- GPU evaluation remains blocked on a LiteRT-LM Android release with working GPU decode for E4B

See [evaluation/reports/latency_report.md](evaluation/reports/latency_report.md) for details.

### Stability

We evaluate response consistency under repeated identical queries and across varying conversation history lengths, assessing whether the model produces reliable outputs under the constraints of on-device inference.

A dedicated stability benchmark has not yet been published as a separate report. The app already includes single-query execution, cancellation, background-generation handling, and history truncation to fit the context window, but response-consistency numbers are still pending.

### Dangerous Scenario Recognition

A dedicated evaluation of how the app handles high-stakes clinical emergencies — including postpartum hemorrhage, eclampsia, neonatal respiratory distress, and sepsis. We assess whether the model correctly identifies emergency escalation triggers, avoids underreacting to critical presentations, and produces safe, actionable guidance aligned with MOHSW Zanzibar protocols.

This has not yet been isolated as a standalone benchmark. For now, the closest signal is the open-ended judge scoring in [evaluation/reports/eval_report_app_parity_v1.md](evaluation/reports/eval_report_app_parity_v1.md), where on-device models trail GPT-5 most sharply on **accuracy** and **safety**.

## Finetuning

Gemma 3n E4B was finetuned on medical QA data using LoRA by an earlier team member (not deployed in the app). The training code has been removed from this repo; artefacts are archived externally.

- [Finetuning Dataset](https://drive.google.com/drive/folders/1vdheVGdrOTXwekaIrSkve7JF28Tpq1Xf?usp=sharing)
- [Finetuned Model](https://huggingface.co/fiifidawson/mam-ai-gemma-3n-medical-finetuned)

```bash
cd finetune
python3.10 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python main_training.py
```

## License

This project is licensed under [Apache 2.0](LICENSE).
