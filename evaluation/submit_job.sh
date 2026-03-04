#!/bin/bash
# Submit eval job to EPFL RunAI cluster
# Usage: ./submit_job.sh [job-name] [script-name]
#
# Examples:
#   ./submit_job.sh mamai-eval-v5                         # runs run_cluster.sh (GGUF models)
#   ./submit_job.sh mamai-gpt5-eval run_cluster_gpt5.sh   # runs GPT-5 via OpenAI API
#
# Prerequisites:
#   - SSH alias "light" configured for haas001
#   - OPENAI_API_KEY stored on haas001 (in keys/openai_key.txt)
#   - PVC permissions: chmod -R g+w /mnt/light/scratch/users/yiren/

JOB_NAME="${1:-mamai-eval-run}"
SCRIPT_NAME="${2:-run_cluster.sh}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "Error: run_cluster.sh not found at $SCRIPT_PATH"
  exit 1
fi

# Base64 encode the script to avoid quoting issues
B64=$(base64 < "$SCRIPT_PATH" | tr -d '\n')

# Read OpenAI API key from cluster
OPENAI_KEY=$(ssh light 'cat /mnt/light/scratch/users/yiren/keys/openai_key.txt' 2>/dev/null)
if [ -z "$OPENAI_KEY" ]; then
  echo "Error: Could not read OpenAI API key from cluster"
  exit 1
fi

echo "Submitting job: $JOB_NAME"
ssh light "runai submit \
  --name $JOB_NAME \
  --image nvidia/cuda:12.4.1-devel-ubuntu22.04 \
  --pvc light-scratch:/lightscratch \
  --large-shm \
  -e OPENAI_API_KEY=$OPENAI_KEY \
  --gpu 1 \
  --backoff-limit 0 \
  --run-as-gid 84257 \
  --command -- bash -c \"echo $B64 | base64 -d | bash\""

echo ""
echo "Monitor with:"
echo "  ssh light 'runai logs $JOB_NAME -f'"
echo "  ssh light 'ls /mnt/light/scratch/users/yiren/eval_output/*.json'"
echo ""
echo "Download results:"
echo "  scp 'light:/mnt/light/scratch/users/yiren/eval_output/*.json' ~/Downloads/mamai/evaluation/results/"
