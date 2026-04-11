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

| File | Source | Size |
|------|--------|------|
| `models/Gecko_1024_quant.tflite` | `app/model_backup/` | ~139 MB |
| `models/sentencepiece.model` | `app/model_backup/` | ~0.8 MB |
| `models/embeddings.sqlite` | `mamai-medical-guidelines/processed/` | ~43 MB |
| `docs/*.pdf` (60 files) | `mamai-medical-guidelines/raw/` | ~91 MB |

## Setup (first time)

```bash
# Hard-link model files (no extra disk space)
ln app/model_backup/Gecko_1024_quant.tflite device_push/models/
ln app/model_backup/sentencepiece.model device_push/models/
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
