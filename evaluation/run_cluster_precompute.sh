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
OUT_DIR=data/rag_contexts
mkdir -p $OUT_DIR

echo "=== STARTING RAG PRE-COMPUTATION ==="
python3 precompute_retrieval.py \
  --db-path $MODEL_DIR/embeddings.sqlite \
  --gecko-model $MODEL_DIR/Gecko_1024_quant.tflite \
  --tokenizer $MODEL_DIR/sentencepiece.model \
  --output-dir $OUT_DIR \
  --top-k 3 \
  --datasets all

echo "=== PRE-COMPUTATION DONE ==="

# Copy results to PVC for persistence
PERSIST_DIR=/lightscratch/users/yiren/eval_output/rag_contexts
mkdir -p $PERSIST_DIR
cp $OUT_DIR/*.json $PERSIST_DIR/
echo "=== RESULTS COPIED TO $PERSIST_DIR ==="
ls -la $PERSIST_DIR/
