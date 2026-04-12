#!/bin/bash
set -euo pipefail

echo "=== INSTALLING DEPENDENCIES ==="
apt-get update && apt-get install -y python3.10 python3-pip git > /dev/null 2>&1
ln -sf /usr/bin/python3.10 /usr/bin/python3
echo "=== INSTALLING PYTHON PACKAGES ==="
pip3 install --no-cache-dir numpy pandas tqdm sentencepiece ai-edge-litert > /dev/null 2>&1
echo "=== DEPS DONE ==="

REPO_URL="${REPO_URL:-https://github.com/nmrenyi/mamai.git}"
REPO_REF="${REPO_REF:-main}"
WORKTREE="${WORKTREE:-/tmp/eval_code}"
DATA_SOURCE_DIR="${DATA_SOURCE_DIR:-/lightscratch/users/yiren/eval_code/data}"
DB_PATH="${DB_PATH:-/lightscratch/users/yiren/model_backup/embeddings.sqlite}"
GECKO_MODEL="${GECKO_MODEL:-/lightscratch/users/yiren/model_backup/Gecko_1024_quant.tflite}"
TOKENIZER="${TOKENIZER:-/lightscratch/users/yiren/model_backup/sentencepiece.model}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/lightscratch/users/yiren/eval_output/rag_contexts}"
CONTEXT_VERSION="${CONTEXT_VERSION:-ragctx-$(date -u +%Y%m%dT%H%M%SZ)}"
OUTPUT_DIR="${OUTPUT_DIR:-$OUTPUT_ROOT/$CONTEXT_VERSION}"
DATASETS="${DATASETS:-all}"
TOP_K="${TOP_K:-3}"
MAX_QUESTIONS="${MAX_QUESTIONS:-}"
MEDMCQA_MAX_QUESTIONS="${MEDMCQA_MAX_QUESTIONS:-500}"

echo "=== CHECKOUT ==="
rm -rf "$WORKTREE"
git clone --branch "$REPO_REF" --depth 1 "$REPO_URL" "$WORKTREE"
cd "$WORKTREE/evaluation"
rm -rf data
ln -s "$DATA_SOURCE_DIR" data

mkdir -p "$OUTPUT_DIR"

if [ "$DATASETS" = "all" ]; then
  DATASET_LIST=(
    "afrimedqa_mcq"
    "medqa_usmle"
    "medmcqa_mcq"
    "kenya_vignettes"
    "whb_stumps"
    "afrimedqa_saq"
  )
else
  IFS=',' read -r -a DATASET_LIST <<< "$DATASETS"
fi

echo "=== STARTING RAG PRECOMPUTATION ==="
echo "REPO_REF=$REPO_REF"
echo "CONTEXT_VERSION=$CONTEXT_VERSION"
echo "OUTPUT_DIR=$OUTPUT_DIR"
echo "TOP_K=$TOP_K"
echo "DATASETS=${DATASET_LIST[*]}"

for RAW_DS in "${DATASET_LIST[@]}"; do
  DS="$(echo "$RAW_DS" | xargs)"
  if [ -z "$DS" ]; then
    continue
  fi

  if [ -f "$OUTPUT_DIR/${DS}.json" ]; then
    echo "SKIP $DS: already exists"
    continue
  fi

  DATASET_ARGS=(
    --db-path "$DB_PATH"
    --gecko-model "$GECKO_MODEL"
    --tokenizer "$TOKENIZER"
    --output-dir "$OUTPUT_DIR"
    --context-version "$CONTEXT_VERSION"
    --top-k "$TOP_K"
    --datasets "$DS"
  )

  if [ -n "$MAX_QUESTIONS" ]; then
    DATASET_ARGS+=(--max-questions "$MAX_QUESTIONS")
  elif [ "$DS" = "medmcqa_mcq" ] && [ -n "$MEDMCQA_MAX_QUESTIONS" ]; then
    DATASET_ARGS+=(--max-questions "$MEDMCQA_MAX_QUESTIONS")
  fi

  echo "Processing $DS..."
  python3 precompute_retrieval.py "${DATASET_ARGS[@]}"
done

echo "=== PRECOMPUTE COMPLETE ==="
find "$OUTPUT_DIR" -maxdepth 1 -type f | sort
