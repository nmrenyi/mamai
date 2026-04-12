# device_push

A staging folder with all files needed to set up the app on an Android device.
Large binaries are gitignored — populate them via the sync/push scripts (see
below).

## Structure

```
device_push/
├── bundle/     # sync-managed RAG assets — rm -rf bundle/ to wipe (gitignored)
│   ├── embeddings.sqlite
│   ├── docs/   # 55 source PDFs, normalized filenames
│   └── debug/  # provenance stamp + chunks_for_rag.txt
├── models/     # static ML model files, populated by sync_models.sh (gitignored)
│   ├── Gecko_1024_quant.tflite
│   ├── sentencepiece.model
│   ├── gemma-4-E4B-it.litertlm
│   ├── gemma-3n-E4B-it-int4.litertlm
│   └── gemma-3n-E4B-it-int4.task
```

`bundle/` is entirely owned by `sync_rag_assets.sh` — it is atomically rebuilt on every sync run, including its `debug/` provenance stamp. `models/` is never touched by the sync script. To wipe everything the sync produced: `rm -rf device_push/bundle/`.

## Contents

### Static ML models (populate via script or manual copy)
| File | Format | Notes |
|------|--------|-------|
| `models/gemma-4-E4B-it.litertlm` | LiteRT-LM | Current deployed model |
| `models/gemma-3n-E4B-it-int4.litertlm` | LiteRT-LM | Previous deployed model (quality baseline) |
| `models/gemma-3n-E4B-it-int4.task` | MediaPipe | Kept for MediaPipe compatibility testing |
| `models/Gecko_1024_quant.tflite` | TFLite | Embedding model |
| `models/sentencepiece.model` | tokenizer | Tokenizer for Gecko |

### RAG bundle assets (managed by sync script)
| File | Source | Size |
|------|--------|------|
| `bundle/embeddings.sqlite` | pre-computed embeddings for 21,731 chunks | ~89 MB |
| `bundle/docs/*.pdf` (55 files) | source medical guidelines, URL-safe names | ~91 MB |
| `bundle/debug/rag_bundle_staged.json` | staged bundle provenance | small |

PDF filenames use normalized SOURCE ids (spaces/parens → underscores, e.g.
`WHO_Abortion_Care_2022.pdf`). `openPdf()` in `MainActivity.kt` applies the
same normalization rule before resolving the path.

## Setup — RAG assets

The pinned bundle version is recorded in `config/rag_assets.lock.json`.
Run the sync script to fetch and install the pinned GitHub release:

```bash
# Update config/rag_assets.lock.json first if you want a newer bundle:
bash scripts/sync_rag_assets.sh

# Optional: use aria2c for faster download/progress output
bash scripts/sync_rag_assets.sh --aria2c
```

The sync script atomically wipes and rebuilds `device_push/bundle/` from the
pinned GitHub release, then writes `debug/rag_bundle_staged.json` recording
exactly which bundle version is staged. By default it prefers `gh` for GitHub
release asset downloads; `--aria2c` is an explicit override for faster
transfer. To wipe the staged bundle entirely: `rm -rf device_push/bundle/`.

## Setup — LLM models (first time)

```bash
# Download the public model artifacts into device_push/models/
bash scripts/sync_models.sh

# Optional: only fetch Gecko + tokenizer
bash scripts/sync_models.sh --gecko-only
```

## Push to device

```bash
# Push staged RAG assets (embeddings.sqlite + PDFs + provenance stamp)
bash scripts/push_to_device.sh

# Also push Gecko + sentencepiece.model
bash scripts/push_to_device.sh --embedding-models

# If multiple devices are connected
bash scripts/push_to_device.sh --serial <device-id>
```

`push_to_device.sh` verifies that the staged bundle in `device_push/` matches
`config/rag_assets.lock.json` before pushing. If the staging area is stale or partial,
it fails and tells you to rerun `sync_rag_assets.sh`. After a full successful
push, it writes `rag_bundle_deployed.json` on the Android device as the device's
deployment receipt.

The device directory corresponds to `getExternalFilesDir(null)` on Android. The
Gemma `.litertlm` model is still handled separately (manual sideload or
first-launch download), because the RAG bundle workflow only manages the
embeddings database and source PDFs.
