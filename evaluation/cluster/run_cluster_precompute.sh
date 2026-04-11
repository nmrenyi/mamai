#!/bin/bash
set -e
echo "=== INSTALLING DEPENDENCIES ==="
apt-get update && apt-get install -y python3.10 python3-pip git > /dev/null 2>&1
ln -sf /usr/bin/python3.10 /usr/bin/python3
echo "=== INSTALLING PYTHON PACKAGES ==="
pip3 install --no-cache-dir numpy pandas tqdm sentencepiece ai-edge-litert > /dev/null 2>&1
echo "=== DEPS DONE ==="

rm -rf /tmp/eval_code
git clone --branch eval --depth 1 https://github.com/nmrenyi/mamai.git /tmp/eval_code
cd /tmp/eval_code/evaluation
ln -s /lightscratch/users/yiren/eval_code/data data

MODEL_DIR=/lightscratch/users/yiren/model_backup
OUT_DIR=/lightscratch/users/yiren/eval_output/rag_contexts
mkdir -p $OUT_DIR

echo "=== STARTING RAG PRE-COMPUTATION ==="

# Run each dataset individually, writing directly to PVC.
# Skip datasets that already have results (survives container restarts).
for ds in afrimedqa_mcq medqa_usmle kenya_vignettes whb_stumps afrimedqa_saq; do
  if [ -f "$OUT_DIR/${ds}.json" ]; then
    echo "SKIP $ds: already exists on PVC"
    continue
  fi
  echo "Processing $ds..."
  python3 precompute_retrieval.py \
    --db-path $MODEL_DIR/embeddings.sqlite \
    --gecko-model $MODEL_DIR/Gecko_1024_quant.tflite \
    --tokenizer $MODEL_DIR/sentencepiece.model \
    --output-dir $OUT_DIR \
    --top-k 3 \
    --datasets $ds
done

# medmcqa_mcq: only first 500 (matches eval cap)
if [ -f "$OUT_DIR/medmcqa_mcq.json" ]; then
  echo "SKIP medmcqa_mcq: already exists on PVC"
else
  echo "Processing medmcqa_mcq (capped at 500)..."
  python3 precompute_retrieval.py \
    --db-path $MODEL_DIR/embeddings.sqlite \
    --gecko-model $MODEL_DIR/Gecko_1024_quant.tflite \
    --tokenizer $MODEL_DIR/sentencepiece.model \
    --output-dir $OUT_DIR \
    --top-k 3 \
    --datasets medmcqa_mcq \
    --max-questions 500
fi

echo "=== ALL DONE ==="
ls -lh $OUT_DIR/
