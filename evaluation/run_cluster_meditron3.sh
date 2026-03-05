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

echo "=== STARTING MEDITRON3 8B EVALUATIONS ==="
for ds in afrimedqa_mcq medqa_usmle kenya_vignettes whb_stumps afrimedqa_saq; do
  python3 run_eval.py --model meditron3-8b --datasets $ds --judge \
    --model-dir /lightscratch/users/yiren/models \
    --output-dir $OUT \
    > ${OUT}/eval_meditron3_${ds}.log 2>&1 &
  echo "Started $ds (PID $!)"
done

python3 run_eval.py --model meditron3-8b --datasets medmcqa_mcq --max-questions 500 --judge \
  --model-dir /lightscratch/users/yiren/models \
  --output-dir $OUT \
  > ${OUT}/eval_meditron3_medmcqa_mcq.log 2>&1 &
echo "Started medmcqa_mcq capped at 500 (PID $!)"

echo "=== ALL JOBS LAUNCHED, WAITING ==="
wait
echo "=== ALL DONE ==="
ls -la $OUT/meditron3-8b/*/
