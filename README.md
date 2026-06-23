# MAM-AI

<p align="center">
  <img src="app/images/logo.png" alt="MAM-AI Logo" width="180"/>
</p>

<p align="center">
  <strong>On-device medical search for nurses and midwives in Zanzibar</strong>
</p>

<p align="center">
  <a href="https://youtu.be/M_Kruluel28">Demo video</a> · <a href="https://nmrenyi-mamai-demo.hf.space">Live web demo</a> · <a href="evaluation/reports/eval_report_app_parity_v1.md">Eval Report</a> · <a href="evaluation/reports/latency_report.md">Latency Report</a>
</p>

---

Android app that answers clinical questions offline using on-device RAG — Gemma 4 E4B (LiteRT-LM) for generation, EmbeddingGemma-300M for embeddings, SQLite for vector search. English only. No internet needed after the initial ~3.8 GB model download.

**🏥 [Try the live web demo](https://nmrenyi-mamai-demo.hf.space)** — a faithful, browser-based mirror of the on-device app (same Gemma 4 + G1 prompt + EmbeddingGemma RAG, served via llama.cpp). Demonstration only — not medical advice; don't read latency from it. ([demo source](https://github.com/nmrenyi/mamai-demo))

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
│  │  │ Gemma 4  │ │ Embedding│ │  SQLite    │ │ │
│  │  │ LiteRT-LM│ │ Gemma    │ │ VectorStore│ │ │
│  │  └──────────┘ └──────────┘ └────────────┘ │ │
│  └────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

Query → EmbeddingGemma embeds → SQLite retrieves top-3 guideline chunks → prompt assembled → LiteRT-LM streams response → Flutter renders markdown.

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

Downloaded on first launch — no auth required. The Gemma 4 LiteRT-LM is the ungated
community export; the EmbeddingGemma retriever is a byte-identical ungated copy of the
license-gated `litert-community/embeddinggemma-300m` under the project's HuggingFace
account. Each file is verified against a pinned SHA-256 before use.

| File | Size | Source |
|---|---|---|
| `gemma-4-E4B-it.litertlm` | 3.66 GB | [litert-community/gemma-4-E4B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) (ungated) |
| `embeddinggemma-300M_seq256_mixed-precision.tflite` | 171 MB | [nmrenyi/embeddinggemma-300m-litert-mamai](https://huggingface.co/nmrenyi/embeddinggemma-300m-litert-mamai) (mirror of gated `litert-community/embeddinggemma-300m`) |
| `embeddinggemma_tokenizer.model` | 4.5 MB | [nmrenyi/embeddinggemma-300m-litert-mamai](https://huggingface.co/nmrenyi/embeddinggemma-300m-litert-mamai) |
| `embeddings.sqlite` | ~261 MB | [mamai-medical-guidelines releases](https://github.com/nmrenyi/mamai-medical-guidelines/releases) |

The pinned RAG bundle version lives in `config/rag_assets.lock.json`; the pinned
model checksums live in `_modelFileSha256` in `app/lib/screens/intro_page.dart`.

## Updating RAG Assets

Chunking and embedding are managed in the companion [mamai-medical-guidelines](https://github.com/nmrenyi/mamai-medical-guidelines) repo. To pull in a new bundle:

1. Bump `config/rag_assets.lock.json` with the new version + manifest checksum
2. Run the staging and push scripts:

```bash
bash scripts/sync_rag_assets.sh          # download + stage bundle
bash scripts/sync_models.sh              # download EmbeddingGemma + Gemma 4 from HuggingFace
bash scripts/push_to_device.sh           # push everything to connected device
bash scripts/push_to_device.sh --embedding-models  # push embedder + tokenizer only
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
| **Gemma 4 E4B (deployed, +G1 prompt, no-RAG)** | **42.9%** | **2.61 / 5** |
| Gemma 3n E4B (no-RAG) | 45.5% | 2.98 / 5 |

The deployed generator is **Gemma 4 E4B with the G1 deflection-fix prompt**, chosen for
**safety**: a generator × prompt evaluation (see the `mamai-eval` repo) found Gemma 3n more
helpful (≈2× Kenya recall) but materially less safe — genuine order-of-magnitude dosing/drug
errors under the same prompts (hand-adjudicated), whereas Gemma 4 + G1 fixes the deflection
problem with ~zero dangerous answers. The retriever is **EmbeddingGemma-300M**. RAG slightly
hurts the on-device models on MCQ (a knowledge proxy); GPT-5 is unaffected.

On an OPPO Snapdragon 8 Elite device, the deployed Gemma 4 E4B averages **~11.7 s TTFT**, with
EmbeddingGemma query embedding + vector search around **0.5–0.6 s** (faster than Gecko's ~2.3 s).

With LiteRT-LM 0.11.0 on GPU (opt-in), TTFT drops to ~1–2 s on the same device; decode rate is unchanged. Multi-token Prediction (`ExperimentalFlags.enableSpeculativeDecoding`, gated behind the `useMtpForLlm` Gradle property) was smoke-tested and produced a **~10–20% decode slowdown** rather than the vendor's claimed >2× — drafter acceptance is likely poor for our long retrieved-context prompts. Off by default; re-test before re-enabling.

Full results: [eval report](evaluation/reports/eval_report_app_parity_v1.md) · [latency report](evaluation/reports/latency_report.md)

## Finetuning (archived)

Gemma 3n E4B was finetuned on medical QA data using LoRA (not deployed). Training code removed; artefacts archived externally: [dataset](https://drive.google.com/drive/folders/1vdheVGdrOTXwekaIrSkve7JF28Tpq1Xf?usp=sharing) · [model](https://huggingface.co/fiifidawson/mam-ai-gemma-3n-medical-finetuned).

## License

[Apache 2.0](LICENSE)
