#!/bin/bash
set -euo pipefail

echo "=== INSTALLING DEPENDENCIES ==="
apt-get update && apt-get install -y python3.10 python3-pip ninja-build git > /dev/null 2>&1
ln -sf /usr/bin/python3.10 /usr/bin/python3
echo "=== INSTALLING PYTHON PACKAGES ==="
CMAKE_ARGS="-DGGML_CUDA=on" FORCE_CMAKE=1 pip3 install --no-cache-dir llama-cpp-python pandas "openai>=1.0.0" tqdm > /dev/null 2>&1
echo "=== DEPS DONE ==="

REPO_URL="${REPO_URL:-https://github.com/nmrenyi/mamai.git}"
REPO_REF="${REPO_REF:-main}"
WORKTREE="${WORKTREE:-/tmp/eval_code}"
DATA_SOURCE_DIR="${DATA_SOURCE_DIR:-/lightscratch/users/yiren/eval_code/data}"
MODEL="${MODEL:-gemma3n-e4b}"
MODEL_DIR="${MODEL_DIR:-/lightscratch/users/yiren/models}"
OUTPUT_DIR="${OUTPUT_DIR:-/lightscratch/users/yiren/eval_output}"
DATASETS="${DATASETS:-all}"
JUDGE="${JUDGE:-0}"
JUDGE_MODEL="${JUDGE_MODEL:-}"
RAG_DIR="${RAG_DIR:-}"
RUN_DIR="${RUN_DIR:-}"
LOG_DIR="${LOG_DIR:-}"
MAX_QUESTIONS="${MAX_QUESTIONS:-}"
MEDMCQA_MAX_QUESTIONS="${MEDMCQA_MAX_QUESTIONS:-500}"
MAX_TOKENS="${MAX_TOKENS:-}"
N_GPU_LAYERS="${N_GPU_LAYERS:-}"

echo "=== CHECKOUT ==="
rm -rf "$WORKTREE"
git clone --branch "$REPO_REF" --depth 1 "$REPO_URL" "$WORKTREE"
cd "$WORKTREE/evaluation"
rm -rf data
ln -s "$DATA_SOURCE_DIR" data

mkdir -p "$OUTPUT_DIR"
if [ -z "$RUN_DIR" ]; then
  RUN_ID="$(date -u +%Y%m%dT%H%M%S)"
  RUN_DIR="$OUTPUT_DIR/$MODEL/$RUN_ID"
fi
mkdir -p "$RUN_DIR"
if [ -z "$LOG_DIR" ]; then
  LOG_DIR="$RUN_DIR/logs"
fi
mkdir -p "$LOG_DIR"

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

COMMON_ARGS=(
  --model "$MODEL"
  --model-dir "$MODEL_DIR"
  --output-dir "$OUTPUT_DIR"
  --run-dir "$RUN_DIR"
)

if [ "$JUDGE" = "1" ]; then
  COMMON_ARGS+=(--judge)
  if [ -n "$JUDGE_MODEL" ]; then
    COMMON_ARGS+=(--judge-model "$JUDGE_MODEL")
  fi
fi

if [ -n "$RAG_DIR" ]; then
  COMMON_ARGS+=(--rag "$RAG_DIR")
fi

if [ -n "$MAX_TOKENS" ]; then
  COMMON_ARGS+=(--max-tokens "$MAX_TOKENS")
fi

if [ -n "$N_GPU_LAYERS" ]; then
  COMMON_ARGS+=(--n-gpu-layers "$N_GPU_LAYERS")
fi

echo "=== STARTING EVALUATIONS ==="
echo "MODEL=$MODEL"
echo "REPO_REF=$REPO_REF"
echo "RUN_DIR=$RUN_DIR"
echo "DATASETS=${DATASET_LIST[*]}"
if [ -n "$RAG_DIR" ]; then
  echo "RAG_DIR=$RAG_DIR"
else
  echo "RAG_DIR=<disabled>"
fi

PIDS=()
for RAW_DS in "${DATASET_LIST[@]}"; do
  DS="$(echo "$RAW_DS" | xargs)"
  if [ -z "$DS" ]; then
    continue
  fi

  DATASET_ARGS=("${COMMON_ARGS[@]}" --datasets "$DS")
  if [ -n "$MAX_QUESTIONS" ]; then
    DATASET_ARGS+=(--max-questions "$MAX_QUESTIONS")
  elif [ "$DS" = "medmcqa_mcq" ] && [ -n "$MEDMCQA_MAX_QUESTIONS" ]; then
    DATASET_ARGS+=(--max-questions "$MEDMCQA_MAX_QUESTIONS")
  fi

  LOG_PATH="$LOG_DIR/eval_${MODEL}_${DS}.log"
  python3 run_eval.py "${DATASET_ARGS[@]}" > "$LOG_PATH" 2>&1 &
  PID="$!"
  PIDS+=("$PID")
  echo "Started $DS (PID $PID) -> $LOG_PATH"
done

echo "=== ALL JOBS LAUNCHED, WAITING ==="
FAIL=0
for PID in "${PIDS[@]}"; do
  if ! wait "$PID"; then
    FAIL=1
  fi
done

echo "=== RUN COMPLETE ==="
find "$RUN_DIR" -maxdepth 2 -type f | sort

if [ "$FAIL" -ne 0 ]; then
  echo "One or more evaluation jobs failed."
  exit 1
fi
