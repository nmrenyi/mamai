# device_push

A staging folder with all files needed to set up the app on an Android device.
Large binaries are gitignored — populate them locally before pushing.

## Contents

| File | Source | Size |
|------|--------|------|
| `gemma-3n-E4B-it-int4.task` | `app/model_backup/` | ~4.1 GB |
| `Gecko_1024_quant.tflite` | `app/model_backup/` | ~139 MB |
| `sentencepiece.model` | `app/model_backup/` | ~0.8 MB |
| `embeddings.sqlite` | `mamai-medical-guidelines/processed/` | ~43 MB |
| `*.pdf` (60 files) | `mamai-medical-guidelines/raw/` (flat) | ~91 MB |

## Setup (first time)

```bash
# Hard-link model files (no extra disk space)
ln app/model_backup/gemma-3n-E4B-it-int4.task device_push/
ln app/model_backup/Gecko_1024_quant.tflite device_push/
ln app/model_backup/sentencepiece.model device_push/
ln ../mamai-medical-guidelines/processed/embeddings.sqlite device_push/

# Copy PDFs flat
find ../mamai-medical-guidelines/raw -name "*.pdf" -exec cp {} device_push/ \;
```

## Push to device

```bash
for f in device_push/*; do
  ~/Library/Android/sdk/platform-tools/adb push "$f" /sdcard/Android/data/com.example.app/files/
done
```

The device directory corresponds to `getExternalFilesDir(null)` on Android.
