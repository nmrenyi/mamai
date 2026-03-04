#!/bin/bash
set -e
echo "=== INSTALLING DEPENDENCIES ==="
apt-get update && apt-get install -y python3.10 python3-pip git > /dev/null 2>&1
ln -sf /usr/bin/python3.10 /usr/bin/python3
echo "=== INSTALLING PYTHON PACKAGES ==="
pip3 install --no-cache-dir pandas "openai>=1.0.0" tqdm > /dev/null 2>&1
echo "=== DEPS DONE ==="

rm -rf /tmp/eval_code
git clone --branch eval --depth 1 https://github.com/nmrenyi/mamai.git /tmp/eval_code
cd /tmp/eval_code/evaluation
ln -s /lightscratch/users/yiren/eval_code/data data
OUT=/lightscratch/users/yiren/eval_output
RAG=/lightscratch/users/yiren/eval_output/rag_contexts
mkdir -p $OUT

echo "=== RESUMING GPT-5 + RAG (incomplete datasets) ==="
# Only resume datasets that were incomplete when suspended
for ds in afrimedqa_mcq medqa_usmle kenya_vignettes; do
  python3 run_eval.py --model gpt-5 --datasets $ds --judge --rag $RAG --resume \
    --output-dir $OUT \
    > ${OUT}/eval_gpt5_rag_resume_${ds}.log 2>&1 &
  echo "Started $ds resume (PID $!)"
done

echo "=== ALL JOBS LAUNCHED, WAITING ==="
wait
echo "=== ALL DONE ==="
ls -la $OUT/gpt-5/*/
