#!/bin/bash
# Submit eval job to EPFL RunAI cluster
# Usage: ./submit_job.sh [job-name]
#
# Prerequisites:
#   - SSH alias "light" configured for haas001
#   - GEMINI_API_KEY set on haas001 (in ~/.bashrc or export)
#   - PVC permissions: chmod -R g+w /mnt/light/scratch/users/yiren/

JOB_NAME="${1:-mamai-eval-run}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/run_cluster.sh"

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "Error: run_cluster.sh not found at $SCRIPT_PATH"
  exit 1
fi

# Base64 encode the script to avoid quoting issues
B64=$(base64 < "$SCRIPT_PATH" | tr -d '\n')

# Read Gemini API key from cluster
GEMINI_KEY=$(ssh light 'cat /mnt/light/scratch/users/yiren/keys/gemini_key.txt' 2>/dev/null)
if [ -z "$GEMINI_KEY" ]; then
  echo "Error: Could not read Gemini API key from cluster"
  exit 1
fi

echo "Submitting job: $JOB_NAME"
ssh light "runai submit \
  --name $JOB_NAME \
  --image nvidia/cuda:12.4.1-devel-ubuntu22.04 \
  --pvc light-scratch:/lightscratch \
  --large-shm \
  -e GEMINI_API_KEY=$GEMINI_KEY \
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
