#!/usr/bin/env bash
# sync_models.sh — Download AI model files from HuggingFace into device_push/models/
#
# Downloads:
#   gemma-3n-E4B-it-int4.litertlm (4.92 GB) from nmrenyi/gemma-3n-E4B-it-litert-lm
#   Gecko_1024_quant.tflite       (146 MB)  from litert-community/Gecko-110m-en
#   sentencepiece.model           (794 KB)  from litert-community/Gecko-110m-en
#
# All public on HuggingFace — no token required. The Gemma 3n repo above is a
# byte-identical, ungated copy of the (license-gated) official
# google/gemma-3n-E4B-it-litert-lm, redistributed under the Gemma Terms of Use
# so the app can fetch it without per-user gating. HF_TOKEN is still honored if
# set (e.g. to pull straight from the gated official repo).
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
GEMMA_REPO="nmrenyi/gemma-3n-E4B-it-litert-lm"
HF_TOKEN="${HF_TOKEN:-}"

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
  local auth=()
  [[ -n "$HF_TOKEN" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  if ! curl -fL --show-error --retry 3 --retry-all-errors --progress-bar "${auth[@]}" -o "$dest.tmp" "$url"; then
    rm -f "$dest.tmp"
    return 1
  fi
  mv "$dest.tmp" "$dest"
  echo "  -> $dest"
}

if [[ "$GECKO_ONLY" -eq 0 ]]; then
  download_file "gemma-3n-E4B-it-int4.litertlm" \
    "$HF/$GEMMA_REPO/resolve/main/gemma-3n-E4B-it-int4.litertlm"
fi

download_file "Gecko_1024_quant.tflite" \
  "$HF/$GECKO_REPO/resolve/main/Gecko_1024_quant.tflite"

download_file "sentencepiece.model" \
  "$HF/$GECKO_REPO/resolve/main/sentencepiece.model"

echo ""
echo "Models ready in $MODELS_DIR"
echo "Next: bash scripts/push_to_device.sh --embedding-models"
echo "Note: this pushes only Gecko + sentencepiece. The Gemma .litertlm is downloaded here for staging/verification and is fetched by the app on first launch."
