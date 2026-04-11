## Evaluation

Benchmarks on-device models on medical QA datasets using batch inference + scoring.

### Structure

```
evaluation/
├── cluster/                    # RunAI cluster job scripts
│   ├── submit_job.sh           # Generic RunAI job submitter
│   ├── run_cluster.sh          # Generic cluster eval entrypoint (env-driven)
│   ├── run_cluster_precompute.sh
│   └── run_cluster_gemma4_e4b_open.sh
├── reports/                    # Final evaluation reports
│   ├── eval_report_app_parity_v1.md   # Current: 3-model MCQ + open-ended (app_parity_v1 protocol)
│   ├── latency_report.md              # Current: on-device latency benchmarks
│   └── legacy/                        # Archived earlier reports
├── data/                       # Benchmark datasets (.tsv)
├── run_eval.py                 # Main evaluation harness
├── scoring.py                  # LLM-as-judge scoring
├── inference.py                # Model registry + inference
├── prompts.py                  # Prompt templates
├── retrieval.py                # RAG retrieval
├── precompute_retrieval.py     # Precompute embeddings
├── benchmark_latency.py        # Latency analysis
├── requirements.txt
└── Dockerfile
```

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

# With OpenAI judge for open-ended datasets
export OPENAI_API_KEY=your-key-here
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

**Submit job** (see `cluster/submit_job.sh` for the full wrapper):
```bash
./cluster/submit_job.sh mamai-gemma4-smoke run_cluster.sh \
  MODEL=gemma4-e4b \
  DATASETS=afrimedqa_mcq \
  MAX_QUESTIONS=5

./cluster/submit_job.sh mamai-gemma4-open-smoke run_cluster.sh \
  MODEL=gemma4-e4b \
  DATASETS=kenya_vignettes \
  MAX_QUESTIONS=5 \
  JUDGE=1

./cluster/submit_job.sh mamai-gemma4-rag-smoke run_cluster.sh \
  MODEL=gemma4-e4b \
  DATASETS=afrimedqa_mcq \
  MAX_QUESTIONS=5 \
  RAG_DIR=/lightscratch/users/yiren/eval_output/rag_contexts/<context-version>
```

`submit_job.sh` automatically forwards the current local Git branch as `REPO_REF`
unless you override it explicitly. Extra `KEY=VALUE` arguments are passed
through to the cluster script as environment variables.

**Versioned RAG context precompute:**
```bash
./cluster/submit_job.sh mamai-rag-precompute run_cluster_precompute.sh \
  CONTEXT_VERSION=app-parity-v1-topk3-v1 \
  DATASETS=all
```

This writes a versioned directory under `eval_output/rag_contexts/<context-version>/`
with one JSON per dataset plus `manifest.json`. `+RAG` evaluation jobs should point
`RAG_DIR` at that exact versioned directory, not at the mutable `rag_contexts/` root.

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
  "metadata": {
    "model": "gemma3n-e4b",
    "dataset": "afrimedqa_mcq",
    "protocol_version": "app_parity_v1",
    "rag_context": {
      "dir": "/lightscratch/users/yiren/eval_output/rag_contexts/app-parity-v1-topk3-v1",
      "context_version": "app-parity-v1-topk3-v1",
      "manifest_sha256": "..."
    }
  },
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
