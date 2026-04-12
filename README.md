# MAM-AI

<p align="center">
  <img src="app/images/logo.png" alt="MAM-AI Logo" width="180"/>
</p>

<p align="center">
  <strong>On-device medical search for nurses and midwives in Zanzibar</strong>
</p>

<p align="center">
  <a href="https://youtu.be/M_Kruluel28">Demo</a> · <a href="evaluation/reports/eval_report_app_parity_v1.md">Eval Report</a> · <a href="evaluation/reports/latency_report.md">Latency Report</a>
</p>

---

Android app that answers clinical questions offline using on-device RAG — Gemma 4 E4B (LiteRT-LM) for generation, Gecko for embeddings, SQLite for vector search. No internet needed after the initial ~4.5 GB model download.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Flutter UI (Dart)                              │
│  intro_page.dart · search_page.dart             │
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

Query → Gecko embeds → SQLite retrieves top-3 guideline chunks → prompt assembled → LiteRT-LM streams response → Flutter renders markdown.

## Build & Run

Requires a real Android device (LiteRT-LM needs hardware acceleration, not emulators).

```bash
cd app
flutter pub get
flutter run              # debug on connected device
flutter build apk        # release APK
adb logcat -s mam-ai     # timing, memory, inference logs
```

## Install

Download the APK from [Releases](../../releases) and sideload onto a real Android device.

## Model Files

Downloaded on first launch from public HuggingFace repos — no auth required.

| File | Size | Source |
|---|---|---|
| `gemma-4-E4B-it.litertlm` | 3.65 GB | [litert-community/gemma-4-E4B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) |
| `Gecko_1024_quant.tflite` | 146 MB | [litert-community/Gecko-110m-en](https://huggingface.co/litert-community/Gecko-110m-en) |
| `sentencepiece.model` | 794 KB | [litert-community/Gecko-110m-en](https://huggingface.co/litert-community/Gecko-110m-en) |
| `embeddings.sqlite` | ~140 MB | [mamai-medical-guidelines releases](https://github.com/nmrenyi/mamai-medical-guidelines/releases) |

The pinned RAG bundle version lives in `config/rag_assets.lock.json`.

## Updating RAG Assets

Chunking and embedding are managed in the companion [mamai-medical-guidelines](https://github.com/nmrenyi/mamai-medical-guidelines) repo. To pull in a new bundle:

1. Bump `config/rag_assets.lock.json` with the new version + manifest checksum
2. Run the staging and push scripts:

```bash
bash scripts/sync_rag_assets.sh          # download + stage bundle
bash scripts/sync_models.sh              # download Gecko + Gemma from HuggingFace
bash scripts/push_to_device.sh           # push everything to connected device
bash scripts/push_to_device.sh --embedding-models  # push Gecko + tokenizer only
```

## Releasing

Tag from `main` only. CI builds a signed APK and publishes a GitHub Release automatically.

```bash
git tag v0.1.0-beta.1    # beta/alpha/rc → prerelease; vX.Y.Z → stable
git push origin v0.1.0-beta.1
```

Valid formats: `vX.Y.Z`, `vX.Y.Z-alpha.N`, `vX.Y.Z-beta.N`, `vX.Y.Z-rc.N`

Required GitHub secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. See [`app/android/key.properties.example`](app/android/key.properties.example) for local signing setup.

## Evaluation

Benchmarks run across AfriMedQA, MedQA USMLE, MedMCQA, Kenya Vignettes, AfriMedQA SAQ, and WHB Stumps under the `app_parity_v1` protocol (same system prompt as the APK, versioned RAG contexts).

| Model | MCQ avg | Open-ended avg |
|---|---|---|
| GPT-5 (no-RAG) | 82.8% | 4.19 / 5 |
| Gemma 3n E4B (no-RAG) | 45.5% | 2.98 / 5 |
| **Gemma 4 E4B (deployed, no-RAG)** | **42.9%** | **2.61 / 5** |

RAG slightly hurts both on-device models on MCQ; GPT-5 is unaffected. GPU decode for Gemma 4 E4B is blocked pending a LiteRT-LM Android GPU release.

On an OPPO Snapdragon 8 Elite device, Gemma 4 E4B averages **11.7 s TTFT**, **26.8 s total**, **13.8 tok/s** — slower TTFT than Gemma 3n E4B (6.8 s) despite faster decode.

Full results: [eval report](evaluation/reports/eval_report_app_parity_v1.md) · [latency report](evaluation/reports/latency_report.md)

## Finetuning (archived)

Gemma 3n E4B was finetuned on medical QA data using LoRA (not deployed). Training code removed; artefacts archived externally: [dataset](https://drive.google.com/drive/folders/1vdheVGdrOTXwekaIrSkve7JF28Tpq1Xf?usp=sharing) · [model](https://huggingface.co/fiifidawson/mam-ai-gemma-3n-medical-finetuned).

## License

[Apache 2.0](LICENSE)
