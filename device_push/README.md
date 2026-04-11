# device_push

A staging folder with all files needed to set up the app on an Android device.
Large binaries are gitignored — populate them via the sync script (see below).

## Structure

```
device_push/
├── docs/       # 55 source PDF guidelines, normalized filenames (gitignored)
├── models/     # Gecko_1024_quant.tflite, sentencepiece.model, embeddings.sqlite (gitignored)
└── debug/      # chunks_for_rag.txt + installed bundle metadata (gitignored)
```

## Contents

### LLM models (populate manually)
| File | Format | Notes |
|------|--------|-------|
| `models/gemma-4-E4B-it.litertlm` | LiteRT-LM | Current deployed model |
| `models/gemma-3n-E4B-it-int4.litertlm` | LiteRT-LM | Previous deployed model (quality baseline) |
| `models/gemma-3n-E4B-it-int4.task` | MediaPipe | Kept for MediaPipe compatibility testing |

### RAG assets (managed by sync script)
| File | Source | Size |
|------|--------|------|
| `models/Gecko_1024_quant.tflite` | embedding model | ~139 MB |
| `models/sentencepiece.model` | tokenizer | ~0.8 MB |
| `models/embeddings.sqlite` | pre-computed embeddings for 21,731 chunks | ~89 MB |
| `docs/*.pdf` (55 files) | source medical guidelines, URL-safe names | ~91 MB |
| `debug/rag_bundle_installed.json` | installed bundle provenance | small |

PDF filenames use normalized SOURCE ids (spaces/parens → underscores, e.g.
`WHO_Abortion_Care_2022.pdf`). `openPdf()` in `MainActivity.kt` applies the
same normalization rule before resolving the path.

## Setup — RAG assets

The pinned bundle version is recorded in `rag-assets.lock.json` at the repo root.
Run the sync script to fetch and install the pinned GitHub release:

```bash
# Update rag-assets.lock.json first if you want a newer bundle:
bash scripts/sync_rag_assets.sh
```

The script verifies checksums, clears any old PDFs before installing, and writes
`debug/rag_bundle_installed.json` so `device_push/` records exactly which RAG
bundle version was staged.

## Setup — LLM models (first time)

```bash
# Hard-link LLM models from root models/ dir (no extra disk space)
ln models/gemma-4-E4B-it.litertlm device_push/models/
ln models/gemma-3n-E4B-it-int4.litertlm device_push/models/
```

## Push to device

```bash
# Push RAG assets
for f in device_push/models/embeddings.sqlite device_push/docs/*.pdf; do
  ~/Library/Android/sdk/platform-tools/adb push "$f" /sdcard/Android/data/com.example.app/files/
done

# Push LLM + embedding models (first time or after update)
for f in device_push/models/Gecko_1024_quant.tflite device_push/models/sentencepiece.model \
          device_push/models/gemma-4-E4B-it.litertlm; do
  ~/Library/Android/sdk/platform-tools/adb push "$f" /sdcard/Android/data/com.example.app/files/
done
```

The device directory corresponds to `getExternalFilesDir(null)` on Android.
