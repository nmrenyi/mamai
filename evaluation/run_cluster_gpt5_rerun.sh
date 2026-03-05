#!/bin/bash
# GPT-5 re-evaluation: NoRAG + RAG, all 6 datasets.
# Uses --run-dir for auto-resume: safe to restart if interrupted.
set -e

echo "=== INSTALLING DEPENDENCIES ==="
apt-get update && apt-get install -y python3.10 python3-pip git > /dev/null 2>&1
ln -sf /usr/bin/python3.10 /usr/bin/python3
pip3 install --no-cache-dir pandas "openai>=1.0.0" tqdm > /dev/null 2>&1
echo "=== DEPS DONE ==="

rm -rf /tmp/eval_code
git clone --branch eval --depth 1 https://github.com/nmrenyi/mamai.git /tmp/eval_code
cd /tmp/eval_code/evaluation
ln -s /lightscratch/users/yiren/eval_code/data data

OUT=/lightscratch/users/yiren/eval_output
RAG=$OUT/rag_contexts
NORAG_DIR=$OUT/gpt-5/rerun_norag
RAG_DIR=$OUT/gpt-5/rerun_rag
mkdir -p $NORAG_DIR $RAG_DIR

echo "=== STARTING GPT-5 NoRAG EVALUATIONS ==="
for ds in afrimedqa_mcq medqa_usmle kenya_vignettes whb_stumps afrimedqa_saq; do
  python3 run_eval.py --model gpt-5 --datasets $ds --judge \
    --run-dir $NORAG_DIR --data-dir data \
    > ${OUT}/eval_gpt5_rerun_norag_${ds}.log 2>&1 &
  echo "Started NoRAG $ds (PID $!)"
done
python3 run_eval.py --model gpt-5 --datasets medmcqa_mcq --max-questions 500 --judge \
  --run-dir $NORAG_DIR --data-dir data \
  > ${OUT}/eval_gpt5_rerun_norag_medmcqa_mcq.log 2>&1 &
echo "Started NoRAG medmcqa_mcq (PID $!)"

echo "=== STARTING GPT-5 RAG EVALUATIONS ==="
for ds in afrimedqa_mcq medqa_usmle kenya_vignettes whb_stumps afrimedqa_saq; do
  python3 run_eval.py --model gpt-5 --datasets $ds --judge \
    --rag $RAG --run-dir $RAG_DIR --data-dir data \
    > ${OUT}/eval_gpt5_rerun_rag_${ds}.log 2>&1 &
  echo "Started RAG $ds (PID $!)"
done
python3 run_eval.py --model gpt-5 --datasets medmcqa_mcq --max-questions 500 --judge \
  --rag $RAG --run-dir $RAG_DIR --data-dir data \
  > ${OUT}/eval_gpt5_rerun_rag_medmcqa_mcq.log 2>&1 &
echo "Started RAG medmcqa_mcq (PID $!)"

echo "=== ALL 12 JOBS LAUNCHED, WAITING ==="
wait
echo "=== ALL DONE ==="
echo "--- NoRAG results ---"
ls -la $NORAG_DIR/
echo "--- RAG results ---"
ls -la $RAG_DIR/
