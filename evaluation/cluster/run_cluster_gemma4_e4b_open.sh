#!/bin/bash
set -e

echo "=== INSTALLING DEPENDENCIES ==="
apt-get update && apt-get install -y python3.10 python3-pip ninja-build git > /dev/null 2>&1
ln -sf /usr/bin/python3.10 /usr/bin/python3

echo "=== INSTALLING PYTHON PACKAGES ==="
CMAKE_ARGS="-DGGML_CUDA=on" FORCE_CMAKE=1 pip3 install --no-cache-dir llama-cpp-python pandas "openai>=1.0.0" tqdm > /dev/null 2>&1
echo "=== DEPS DONE ==="

rm -rf /tmp/eval_code
git clone --branch eval --depth 1 https://github.com/nmrenyi/mamai.git /tmp/eval_code
cd /tmp/eval_code/evaluation
ln -s /lightscratch/users/yiren/eval_code/data data

OUT=/lightscratch/users/yiren/eval_output
mkdir -p $OUT

OPEN_DS="kenya_vignettes whb_stumps afrimedqa_saq"

echo "=== STARTING GEMMA 4 E4B OPEN-ENDED EVALUATIONS (NO RAG) ==="
for ds in $OPEN_DS; do
  python3 run_eval.py --model gemma4-e4b --datasets $ds --judge \
    --model-dir /lightscratch/users/yiren/models \
    --output-dir $OUT \
    > ${OUT}/eval_gemma4_e4b_open_${ds}.log 2>&1 &
  echo "Started no-RAG $ds (PID $!)"
done

echo "=== WAITING FOR RUNS ==="
wait

echo "=== ALL DONE ==="
ls -la $OUT/gemma4-e4b/*/
