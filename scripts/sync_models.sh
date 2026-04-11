#!/usr/bin/env bash
# sync_models.sh — Download AI model files from HuggingFace into device_push/models/
#
# Downloads:
#   gemma-4-E4B-it.litertlm   (3.65 GB) from litert-community/gemma-4-E4B-it-litert-lm
#   Gecko_1024_quant.tflite   (146 MB)  from litert-community/Gecko-110m-en
#   sentencepiece.model       (794 KB)  from litert-community/Gecko-110m-en
#
# All files are public on HuggingFace — no token required.
# Files already present are skipped (re-run is idempotent).
#
# Usage:
#   scripts/sync_models.sh               # download all three files
#   scripts/sync_models.sh --gecko-only  # skip Gemma, download only Gecko + tokenizer
#
# Requirements: curl

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="$REPO_ROOT/device_push/models"

HF="https://huggingface.co"
GECKO_REPO="litert-community/Gecko-110m-en"
GEMMA4_REPO="litert-community/gemma-4-E4B-it-litert-lm"

GECKO_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gecko-only)
      GECKO_ONLY=1
      shift
      ;;
    -h|--help)
      awk 'NR >= 2 && NR <= 16 { sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$MODELS_DIR"

download_file() {
  local filename="$1"
  local url="$2"
  local dest="$MODELS_DIR/$filename"

  if [[ -f "$dest" ]]; then
    echo "SKIP $filename (already exists at $dest)"
    return
  fi

  echo "Downloading $filename ..."
  curl -L --progress-bar -o "$dest.tmp" "$url"
  mv "$dest.tmp" "$dest"
  echo "  -> $dest"
}

if [[ "$GECKO_ONLY" -eq 0 ]]; then
  download_file "gemma-4-E4B-it.litertlm" \
    "$HF/$GEMMA4_REPO/resolve/main/gemma-4-E4B-it.litertlm"
fi

download_file "Gecko_1024_quant.tflite" \
  "$HF/$GECKO_REPO/resolve/main/Gecko_1024_quant.tflite"

download_file "sentencepiece.model" \
  "$HF/$GECKO_REPO/resolve/main/sentencepiece.model"

echo ""
echo "Models ready in $MODELS_DIR"
echo "Next: bash scripts/push_to_device.sh --models"
