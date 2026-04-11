# device_push

A staging folder with all files needed to set up the app on an Android device.
Large binaries are gitignored — populate them via the sync/push scripts (see
below).

## Structure

```
device_push/
├── docs/       # 55 source PDF guidelines, normalized filenames (gitignored)
├── models/     # Gecko_1024_quant.tflite, sentencepiece.model, embeddings.sqlite (gitignored)
└── debug/      # chunks_for_rag.txt + staged bundle metadata (gitignored)
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
| `debug/rag_bundle_staged.json` | staged bundle provenance | small |

PDF filenames use normalized SOURCE ids (spaces/parens → underscores, e.g.
`WHO_Abortion_Care_2022.pdf`). `openPdf()` in `MainActivity.kt` applies the
same normalization rule before resolving the path.

## Setup — RAG assets

The pinned bundle version is recorded in `rag-assets.lock.json` at the repo root.
Run the sync script to fetch and install the pinned GitHub release:

```bash
# Update rag-assets.lock.json first if you want a newer bundle:
bash scripts/sync_rag_assets.sh

# Optional: use aria2c for faster download/progress output
bash scripts/sync_rag_assets.sh --aria2c
```

The sync script caches downloaded bundles under `_scratch/rag_bundle_cache/`,
rebuilds the single active staged view in `device_push/`, and writes
`debug/rag_bundle_staged.json` so `device_push/` records exactly which RAG
bundle version is currently staged on the host. By default it prefers `gh`
for GitHub release asset downloads; `--aria2c` is an explicit override when
you want faster transfer/progress output.

## Setup — LLM models (first time)

```bash
# Hard-link LLM models from root models/ dir (no extra disk space)
ln models/gemma-4-E4B-it.litertlm device_push/models/
ln models/gemma-3n-E4B-it-int4.litertlm device_push/models/
```

## Push to device

```bash
# Push staged RAG assets (embeddings.sqlite + PDFs + provenance stamp)
bash scripts/push_to_device.sh

# Also push Gecko + sentencepiece.model
bash scripts/push_to_device.sh --models

# If multiple devices are connected
bash scripts/push_to_device.sh --serial <device-id>
```

`push_to_device.sh` verifies that the staged bundle in `device_push/` matches
`rag-assets.lock.json` before pushing. If the staging area is stale or partial,
it fails and tells you to rerun `sync_rag_assets.sh`. After a full successful
push, it writes `rag_bundle_deployed.json` on the Android device as the device's
deployment receipt.

The device directory corresponds to `getExternalFilesDir(null)` on Android. The
Gemma `.litertlm` model is still handled separately (manual sideload or
first-launch download), because the RAG bundle workflow only manages the
embeddings database and source PDFs.
