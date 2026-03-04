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
mkdir -p $OUT

# Find the best checkpoint for each dataset across all previous runs
# Merge into a single "best" checkpoint dir
BEST=/tmp/best_checkpoint
mkdir -p $BEST
for ds in afrimedqa_mcq medqa_usmle kenya_vignettes; do
  best_file=""
  best_count=0
  for f in $OUT/gpt-5/*//${ds}.json; do
    [ -f "$f" ] || continue
    n=$(python3 -c "import json; print(len(json.load(open('$f'))['results']))" 2>/dev/null || echo 0)
    if [ "$n" -gt "$best_count" ]; then
      best_count=$n
      best_file=$f
    fi
  done
  if [ -n "$best_file" ]; then
    cp "$best_file" "$BEST/${ds}.json"
    echo "Best checkpoint for $ds: $best_count results (from $best_file)"
  fi
done

echo "=== RESUMING GPT-5 EVALUATIONS ==="

for ds in afrimedqa_mcq medqa_usmle kenya_vignettes; do
  python3 run_eval.py --model gpt-5 --datasets $ds --judge \
    --output-dir $OUT --resume $BEST \
    > ${OUT}/eval_gpt5_resume_${ds}.log 2>&1 &
  echo "Started $ds (PID $!)"
done

echo "=== ALL JOBS LAUNCHED, WAITING ==="
wait
echo "=== ALL DONE ==="
ls -la $OUT/gpt-5/*/
