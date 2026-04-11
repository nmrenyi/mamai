"""
Pre-compute RAG retrieval contexts for all evaluation datasets.

Embeds each question using the Gecko TFLite model and retrieves the top-k
most similar chunks from the app's vector store. Results are saved as JSON
files that the eval pipeline can load with --rag.

Usage:
  python precompute_retrieval.py
  python precompute_retrieval.py --top-k 5 --datasets afrimedqa_mcq,whb_stumps
"""

import argparse
import json
import os
from pathlib import Path

import numpy as np
import pandas as pd
from tqdm import tqdm

from prompts import RETRIEVAL_TOP_K
from retrieval import GeckoEmbedder, build_index, load_vector_store, retrieve

# Same dataset registry as run_eval.py
DATASETS = {
    "afrimedqa_mcq": ("afrimedqa_mcq.tsv", "question_clean"),
    "medqa_usmle": ("medqa_usmle.tsv", "question"),
    "medmcqa_mcq": ("medmcqa_mcq.tsv", "question"),
    "kenya_vignettes": ("kenya_vignettes.tsv", "scenario"),
    "whb_stumps": ("whb_stumps.tsv", "question_clean"),
    "afrimedqa_saq": ("afrimedqa_saq.tsv", "question_clean"),
}

_REPO_ROOT = Path(__file__).parents[1]
_APP_CONFIG = json.loads((_REPO_ROOT / "config" / "app_config.json").read_text())

# Default to the current staged device_push layout. Cluster jobs can override these
# explicitly with --db-path/--gecko-model/--tokenizer.
DEFAULT_DB = str(_REPO_ROOT / "device_push" / "bundle" / "embeddings.sqlite")
DEFAULT_GECKO = str(_REPO_ROOT / "device_push" / "models" / _APP_CONFIG["embedding_model"])
DEFAULT_TOKENIZER = str(_REPO_ROOT / "device_push" / "models" / _APP_CONFIG["tokenizer"])


def main():
    parser = argparse.ArgumentParser(description="Pre-compute RAG retrieval contexts")
    parser.add_argument("--db-path", default=DEFAULT_DB, help="Path to embeddings.sqlite")
    parser.add_argument("--gecko-model", default=DEFAULT_GECKO, help="Path to Gecko TFLite model")
    parser.add_argument("--tokenizer", default=DEFAULT_TOKENIZER, help="Path to sentencepiece.model")
    parser.add_argument("--data-dir", default="data", help="Directory containing dataset TSV files")
    parser.add_argument("--output-dir", default="data/rag_contexts", help="Output directory for JSON files")
    parser.add_argument("--top-k", type=int, default=RETRIEVAL_TOP_K, help="Number of chunks to retrieve per question")
    parser.add_argument("--datasets", default="all", help="Comma-separated dataset names, or 'all'")
    parser.add_argument("--max-questions", type=int, default=None, help="Limit questions per dataset")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    # Resolve datasets
    if args.datasets == "all":
        dataset_names = list(DATASETS.keys())
    else:
        dataset_names = [d.strip() for d in args.datasets.split(",")]

    # Load vector store and build index
    store = load_vector_store(args.db_path)
    texts, normed_matrix = build_index(store)

    # Load Gecko embedder
    embedder = GeckoEmbedder(args.gecko_model, args.tokenizer)

    for ds_name in dataset_names:
        if ds_name not in DATASETS:
            print(f"SKIP: unknown dataset {ds_name}")
            continue

        filename, q_col = DATASETS[ds_name]
        filepath = os.path.join(args.data_dir, filename)
        if not os.path.exists(filepath):
            print(f"SKIP: {filepath} not found")
            continue

        print(f"\n{'='*60}")
        print(f"Dataset: {ds_name}")
        print(f"{'='*60}")

        df = pd.read_csv(filepath, sep="\t")
        if args.max_questions:
            df = df.head(args.max_questions)
        print(f"Processing {len(df)} questions")

        retrievals = []
        for _, row in tqdm(df.iterrows(), total=len(df), desc=ds_name):
            question = str(row[q_col]) if pd.notna(row[q_col]) else ""
            if not question:
                retrievals.append({"question": "", "chunks": [], "similarities": []})
                continue

            query_emb = embedder.embed(question)
            results = retrieve(query_emb, texts, normed_matrix, top_k=args.top_k)

            retrievals.append({
                "question": question,
                "chunks": [chunk for chunk, _ in results],
                "similarities": [round(score, 4) for _, score in results],
            })

        output = {
            "config": {
                "top_k": args.top_k,
                "embedding_model": "Gecko_1024_quant",
                "n_chunks_in_store": len(store),
                "n_questions": len(retrievals),
            },
            "retrievals": retrievals,
        }

        output_path = os.path.join(args.output_dir, f"{ds_name}.json")
        with open(output_path, "w") as f:
            json.dump(output, f, indent=2, ensure_ascii=False)
        print(f"Saved: {output_path}")

        # Print sample
        if retrievals and retrievals[0]["chunks"]:
            r = retrievals[0]
            print(f"\nSample — Q: {r['question'][:100]}...")
            for i, (chunk, sim) in enumerate(zip(r["chunks"], r["similarities"])):
                print(f"  [{i+1}] sim={sim:.4f}: {chunk[:80]}...")


if __name__ == "__main__":
    main()
