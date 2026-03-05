## Evaluation

Benchmarks Gemma 3n E4B/E2B and MedGemma on medical QA datasets using batch inference + scoring.

### Datasets

| Dataset | Type | N |
|---|---|---|
| AfriMed-QA MCQ | MCQ | 660 |
| MedQA-USMLE | MCQ | 1,025 |
| MedMCQA (OBGYN) | MCQ | 18,508 |
| Kenya Vignettes | Open | 284 |
| WHB Stumps | Open | 20 |
| AfriMed-QA SAQ | Open | 37 |

### Local usage

```bash
pip install llama-cpp-python
pip install -r requirements.txt

# Quick test (5 questions, CPU)
python run_eval.py --model gemma3n-e4b --model-dir models --datasets afrimedqa_mcq --max-questions 5 --n-gpu-layers 0

# Full MCQ benchmark
python run_eval.py --model gemma3n-e4b --model-dir models --datasets afrimedqa_mcq,medqa_usmle,medmcqa_mcq

# With Gemini judge for open-ended datasets
export GEMINI_API_KEY=your-key-here
python run_eval.py --model gemma3n-e4b --model-dir models --datasets all --judge
```

### Docker (EPFL RunAI cluster)

**Build and push:**
```bash
cd evaluation/
docker build -t registry.rcp.epfl.ch/multimeditron/mamai-eval:latest .
docker push registry.rcp.epfl.ch/multimeditron/mamai-eval:latest
```

**Copy models to PVC:**
```bash
scp models/gemma-3n/gemma-3n-E4B-it-Q4_0.gguf $HOST:/mloscratch/users/$GASPAR/models/gemma-3n/
```

**Submit job:**
```bash
runai submit \
  --name mamai-eval \
  --image registry.rcp.epfl.ch/multimeditron/mamai-eval:latest \
  --pvc light-scratch:/mloscratch \
  --large-shm \
  --gpu 1 \
  --node-pool h100 \
  --run-as-gid 84257 \
  -e MODEL_DIR=/mloscratch/users/$GASPAR/models \
  -e OUTPUT_DIR=/mloscratch/users/$GASPAR/eval_results \
  -e GEMINI_API_KEY_FILE_AT=/mloscratch/users/$GASPAR/keys/gemini_key.txt \
  -- python3 run_eval.py --model gemma3n-e4b --datasets all --judge \
     --model-dir /mloscratch/users/$GASPAR/models \
     --output-dir /mloscratch/users/$GASPAR/eval_results
```

**Interactive debugging:**
```bash
runai submit \
  --name mamai-eval-debug \
  --image registry.rcp.epfl.ch/multimeditron/mamai-eval:latest \
  --pvc light-scratch:/mloscratch \
  --large-shm \
  --gpu 1 \
  --node-pool h100 \
  --run-as-gid 84257 \
  -- sleep infinity

runai exec mamai-eval-debug -it bash
```

### Output format

Results saved as JSON in `results/`:
```json
{
  "metadata": { "model": "gemma3n-e4b", "dataset": "afrimedqa_mcq", ... },
  "aggregate_scores": { "accuracy": 0.45, "correct": 297, "total": 660 },
  "results": [
    { "question": "...", "model_response": "...", "correct": true, ... }
  ]
}
```

### References

1. Qmed Asia: MedGemma for askCPG (Malaysia clinical practice guidelines)
   - https://research.google/blog/next-generation-medical-image-interpretation-with-medgemma-15-and-medical-speech-to-text-with-medasr/
   - Intro https://hello.qmed.asia/
   - Platform https://cpg.qmed.ai/
