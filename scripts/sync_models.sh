#!/usr/bin/env bash
# sync_models.sh — Download AI model files from HuggingFace into device_push/models/
#
# Downloads:
#   gemma-4-E4B-it.litertlm                           (3.66 GB) from litert-community/gemma-4-E4B-it-litert-lm
#   embeddinggemma-300M_seq256_mixed-precision.tflite (171 MB)  from nmrenyi/embeddinggemma-300m-litert-mamai
#   embeddinggemma_tokenizer.model                    (4.5 MB)  from nmrenyi/embeddinggemma-300m-litert-mamai (sentencepiece.model)
#
# All public on HuggingFace — no token required. The Gemma 4 LiteRT-LM is the
# ungated community export; the embedder is the project's ungated, byte-identical
# copy of the (license-gated) litert-community/embeddinggemma-300m. To validate
# against a canonical gated repo, override the repo AND pass a token, e.g.:
#   GEMMA_REPO=google/gemma-4-E4B-it-litert-lm HF_TOKEN=hf_xxx scripts/sync_models.sh
# Files already present are skipped (re-run is idempotent).
#
# Usage:
#   scripts/sync_models.sh                   # download all three files
#   scripts/sync_models.sh --embedder-only   # skip the Gemma LLM, download only the embedder + tokenizer
#
# Requirements: curl

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="$REPO_ROOT/device_push/models"

HF="https://huggingface.co"
# Overridable so maintainers can pull from a canonical gated repo with a token
# (see header). Defaults to the project's ungated, byte-identical copies.
EMBEDDER_REPO="${EMBEDDER_REPO:-nmrenyi/embeddinggemma-300m-litert-mamai}"
GEMMA_REPO="${GEMMA_REPO:-litert-community/gemma-4-E4B-it-litert-lm}"
HF_TOKEN="${HF_TOKEN:-}"

EMBEDDER_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --embedder-only)
      EMBEDDER_ONLY=1
      shift
      ;;
    -h|--help)
      awk 'NR >= 2 && NR <= 22 { sub(/^# ?/, ""); print }' "$0"
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
  # ${auth[@]+...} guards against "unbound variable" on bash 3.2 (macOS) under
  # `set -u` when the array is empty (no HF_TOKEN — the common case).
  if ! curl -fL --show-error --retry 3 --retry-all-errors --progress-bar ${auth[@]+"${auth[@]}"} -o "$dest.tmp" "$url"; then
    rm -f "$dest.tmp"
    return 1
  fi
  mv "$dest.tmp" "$dest"
  echo "  -> $dest"
}

if [[ "$EMBEDDER_ONLY" -eq 0 ]]; then
  download_file "gemma-4-E4B-it.litertlm" \
    "$HF/$GEMMA_REPO/resolve/main/gemma-4-E4B-it.litertlm"
fi

download_file "embeddinggemma-300M_seq256_mixed-precision.tflite" \
  "$HF/$EMBEDDER_REPO/resolve/main/embeddinggemma-300M_seq256_mixed-precision.tflite"

# The tokenizer asset is named sentencepiece.model upstream; stage it under the
# distinct on-device filename the app expects (app_config.json "tokenizer").
download_file "embeddinggemma_tokenizer.model" \
  "$HF/$EMBEDDER_REPO/resolve/main/sentencepiece.model"

echo ""
echo "Models ready in $MODELS_DIR"
echo "Next: bash scripts/push_to_device.sh --embedding-models"
echo "Note: this pushes only the EmbeddingGemma model + tokenizer. The Gemma .litertlm is downloaded here for staging/verification and is fetched by the app on first launch."
