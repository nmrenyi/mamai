# device_push

A staging folder with all files needed to set up the app on an Android device.
Large binaries are gitignored — populate them locally before pushing.

## Structure

```
device_push/
├── docs/       # 60 source PDF guidelines (gitignored)
└── models/     # Gecko_1024_quant.tflite, sentencepiece.model, embeddings.sqlite (gitignored)
```

## Contents

### LLM models
| File | Format | Notes |
|------|--------|-------|
| `models/gemma-4-E4B-it.litertlm` | LiteRT-LM | Current deployed model |
| `models/gemma-3n-E4B-it-int4.litertlm` | LiteRT-LM | Previous deployed model (quality baseline) |
| `models/gemma-3n-E4B-it-int4.task` | MediaPipe | Kept for MediaPipe compatibility testing |

### Supporting files
| File | Source | Size |
|------|--------|------|
| `models/Gecko_1024_quant.tflite` | embedding model | ~139 MB |
| `models/sentencepiece.model` | tokenizer | ~0.8 MB |
| `models/embeddings.sqlite` | pre-computed doc embeddings | ~43 MB |
| `docs/*.pdf` (60 files) | source medical guidelines | ~91 MB |

## Setup (first time)

```bash
# Hard-link LLM models from root models/ dir (no extra disk space)
ln models/gemma-4-E4B-it.litertlm device_push/models/
ln models/gemma-3n-E4B-it-int4.litertlm device_push/models/
# gemma-3n-E4B-it-int4.task is already in device_push/models/

# Hard-link supporting files
ln ../mamai-medical-guidelines/processed/embeddings.sqlite device_push/models/

# Copy PDFs
find ../mamai-medical-guidelines/raw -name "*.pdf" -exec cp {} device_push/docs/ \;
```

## Push to device

```bash
for f in device_push/models/* device_push/docs/*; do
  ~/Library/Android/sdk/platform-tools/adb push "$f" /sdcard/Android/data/com.example.app/files/
done
```

The device directory corresponds to `getExternalFilesDir(null)` on Android.
