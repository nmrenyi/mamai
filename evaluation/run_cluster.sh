#!/bin/bash
set -e
echo "=== INSTALLING DEPENDENCIES ==="
apt-get update && apt-get install -y python3.10 python3-pip ninja-build > /dev/null 2>&1
ln -sf /usr/bin/python3.10 /usr/bin/python3
echo "=== INSTALLING PYTHON PACKAGES ==="
CMAKE_ARGS="-DGGML_CUDA=on" FORCE_CMAKE=1 pip3 install --no-cache-dir llama-cpp-python pandas "google-genai>=1.0.0" tqdm > /dev/null 2>&1
echo "=== DEPS DONE ==="

cd /lightscratch/users/yiren/eval_code
OUT=/lightscratch/users/yiren/eval_output
mkdir -p $OUT

echo "=== STARTING EVALUATIONS ==="
for ds in afrimedqa_mcq medqa_usmle kenya_vignettes whb_stumps afrimedqa_saq; do
  python3 run_eval.py --model gemma3n-e4b --datasets $ds --judge \
    --model-dir /lightscratch/users/yiren/models \
    --output-dir $OUT \
    > ${OUT}/eval_${ds}.log 2>&1 &
  echo "Started $ds (PID $!)"
done

python3 run_eval.py --model gemma3n-e4b --datasets medmcqa_mcq --max-questions 500 \
  --model-dir /lightscratch/users/yiren/models \
  --output-dir $OUT \
  > ${OUT}/eval_medmcqa_mcq.log 2>&1 &
echo "Started medmcqa_mcq capped at 500 (PID $!)"

echo "=== ALL JOBS LAUNCHED, WAITING ==="
wait
echo "=== ALL DONE ==="
ls -la $OUT/
