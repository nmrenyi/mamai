"""
Batch evaluation pipeline for medical QA benchmarks.

Usage:
  python run_eval.py --model gemma3n-e4b --datasets afrimedqa_mcq --max-questions 5
  python run_eval.py --model gemma3n-e4b --datasets all --judge
  python run_eval.py --model gemma3n-e2b --model-dir /mloscratch/users/$USER/models --datasets all
"""

import argparse
import json
import os
import time
from datetime import datetime, timezone

import pandas as pd
from tqdm import tqdm

from inference import load_model
from prompts import TEMPERATURE, TOP_P, TOP_K, N_CTX, PROMPT_VERSION, build_mcq_prompt, build_open_prompt
from scoring import create_judge_client, extract_letters, judge_response, score_mcq

# Dataset registry: name -> (filename, type, question_col, options_col, answer_col, reference_col)
DATASETS = {
    "afrimedqa_mcq": ("afrimedqa_mcq.tsv", "mcq", "question_clean", "options_formatted", "correct_letter", None),
    "medqa_usmle": ("medqa_usmle.tsv", "mcq", "question", "options_formatted", "correct_letter", None),
    "medmcqa_mcq": ("medmcqa_mcq.tsv", "mcq", "question", "options_formatted", "correct_letter", None),
    "kenya_vignettes": ("kenya_vignettes.tsv", "open", "scenario", None, None, "clinician_response"),
    "whb_stumps": ("whb_stumps.tsv", "open", "question_clean", None, None, "expert_justification"),
    "afrimedqa_saq": ("afrimedqa_saq.tsv", "open", "question_clean", None, None, "answer_rationale"),
}

CHECKPOINT_INTERVAL = 100


def run_mcq(model, df, question_col, options_col, answer_col, max_tokens, max_questions,
            output_path=None, metadata=None):
    """Run MCQ evaluation: inference + letter extraction + accuracy."""
    if max_questions:
        df = df.head(max_questions)

    results = []
    predictions = []
    ground_truth = []

    for i, (_, row) in enumerate(tqdm(df.iterrows(), total=len(df), desc="MCQ inference"), 1):
        if pd.isna(row[question_col]) or pd.isna(row[options_col]) or pd.isna(row[answer_col]):
            print(f"  Skipping row {i}: missing question/options/answer")
            continue

        question = str(row[question_col])
        options = str(row[options_col])
        correct = str(row[answer_col]).strip()

        prompt = build_mcq_prompt(question, options)
        t0 = time.time()
        response = model.generate(prompt, max_tokens=max_tokens)
        elapsed = time.time() - t0

        extracted_set = extract_letters(response)
        extracted = ",".join(sorted(extracted_set)) if extracted_set else ""
        predictions.append(extracted)
        ground_truth.append(correct)

        results.append({
            "question": question,
            "options": options,
            "ground_truth": correct,
            "model_response": response,
            "extracted_answer": extracted,
            "extracted_answers": sorted(extracted_set),
            "correct": extracted.upper() == correct.upper(),
            "inference_time_s": round(elapsed, 2),
        })

        if output_path and i % CHECKPOINT_INTERVAL == 0:
            scores = score_mcq(predictions, ground_truth)
            save_checkpoint(output_path, metadata or {}, scores, results)
            print(f"  Checkpoint saved at {i}/{len(df)}")

    scores = score_mcq(predictions, ground_truth)
    return results, scores


def _open_scores(judge_scores):
    """Compute aggregate judge scores."""
    if not judge_scores:
        return {}
    return {
        "mean_judge_score": round(sum(judge_scores) / len(judge_scores), 2),
        "judge_scores_distribution": {i: judge_scores.count(i) for i in range(1, 6)},
        "n_judged": len(judge_scores),
    }


def run_open(model, df, question_col, reference_col, max_tokens, max_questions, judge_client, judge_model,
             output_path=None, metadata=None):
    """Run open-ended evaluation: inference + optional LLM-as-judge scoring."""
    if max_questions:
        df = df.head(max_questions)

    results = []
    judge_scores = []

    for i, (_, row) in enumerate(tqdm(df.iterrows(), total=len(df), desc="Open inference"), 1):
        if pd.isna(row[question_col]):
            print(f"  Skipping row {i}: missing question")
            continue

        question = str(row[question_col])
        reference = str(row[reference_col]) if reference_col and reference_col in row.index and pd.notna(row[reference_col]) else ""

        prompt = build_open_prompt(question)
        t0 = time.time()
        response = model.generate(prompt, max_tokens=max_tokens)
        elapsed = time.time() - t0

        result = {
            "question": question,
            "reference": reference,
            "model_response": response,
            "inference_time_s": round(elapsed, 2),
        }

        # LLM-as-judge scoring
        if judge_client is not None and reference:
            judgment = judge_response(question, response, reference, judge_client, judge_model)
            result["judge_score"] = judgment.get("score") if judgment else None
            result["judge_justification"] = judgment.get("justification") if judgment else None
            if judgment and judgment.get("score") is not None:
                judge_scores.append(judgment["score"])

        results.append(result)

        if output_path and i % CHECKPOINT_INTERVAL == 0:
            save_checkpoint(output_path, metadata or {}, _open_scores(judge_scores), results)
            print(f"  Checkpoint saved at {i}/{len(df)}")

    return results, _open_scores(judge_scores)


def save_checkpoint(output_path, metadata, scores, results):
    """Save current results to a JSON checkpoint file."""
    data = {"metadata": metadata, "aggregate_scores": scores, "results": results}
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser(description="Medical QA Evaluation Pipeline")
    parser.add_argument("--model", required=True, help="Model name (e.g., gemma3n-e4b, gemma3n-e2b)")
    parser.add_argument("--model-dir", default="models", help="Directory containing model files")
    parser.add_argument("--datasets", required=True, help="Comma-separated dataset names, or 'all'")
    parser.add_argument("--output-dir", default="results", help="Directory for output JSON files")
    parser.add_argument("--max-tokens", type=int, default=1024, help="Max tokens to generate")
    parser.add_argument("--max-questions", type=int, default=None, help="Limit questions per dataset (for debugging)")
    parser.add_argument("--judge", action="store_true", help="Enable LLM-as-judge for open-ended datasets")
    parser.add_argument("--judge-model", default="gemini-3-flash-preview", help="Gemini model for judging")
    parser.add_argument("--n-gpu-layers", type=int, default=None, help="GPU layers for GGUF (-1 = all, 0 = CPU, default: auto-detect)")
    parser.add_argument("--data-dir", default="data", help="Directory containing dataset TSV files")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    # Resolve dataset list
    if args.datasets == "all":
        dataset_names = list(DATASETS.keys())
    else:
        dataset_names = [d.strip() for d in args.datasets.split(",")]
        for name in dataset_names:
            if name not in DATASETS:
                parser.error(f"Unknown dataset: {name}. Available: {list(DATASETS.keys())}")

    # Load model once
    model = load_model(args.model, args.model_dir, n_gpu_layers=args.n_gpu_layers)

    # Set up judge if requested
    judge_client, judge_model = None, None
    if args.judge:
        judge_client, judge_model = create_judge_client(args.judge_model)
        if judge_client is None:
            print("WARNING: --judge requested but no GEMINI_API_KEY found. Skipping judge scoring.")

    # Run evaluation for each dataset
    summary = []
    for ds_name in dataset_names:
        filename, ds_type, q_col, opt_col, ans_col, ref_col = DATASETS[ds_name]
        filepath = os.path.join(args.data_dir, filename)

        if not os.path.exists(filepath):
            print(f"SKIP: {filepath} not found")
            continue

        print(f"\n{'='*60}")
        print(f"Dataset: {ds_name} ({ds_type})")
        print(f"{'='*60}")

        df = pd.read_csv(filepath, sep="\t")
        print(f"Loaded {len(df)} rows")

        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
        output_path = os.path.join(args.output_dir, f"{args.model}_{ds_name}_{timestamp}.json")

        metadata = {
            "model": args.model,
            "model_dir": args.model_dir,
            "dataset": ds_name,
            "dataset_type": ds_type,
            "n_questions": min(len(df), args.max_questions or len(df)),
            "timestamp": timestamp,
            "prompt_version": PROMPT_VERSION,
            "generation_params": {
                "temperature": TEMPERATURE,
                "top_p": TOP_P,
                "top_k": TOP_K,
                "n_ctx": N_CTX,
                "max_tokens": args.max_tokens,
            },
        }

        t0 = time.time()
        if ds_type == "mcq":
            results, scores = run_mcq(model, df, q_col, opt_col, ans_col, args.max_tokens, args.max_questions,
                                      output_path, metadata)
        else:
            results, scores = run_open(model, df, q_col, ref_col, args.max_tokens, args.max_questions,
                                       judge_client, judge_model, output_path, metadata)

        elapsed = time.time() - t0
        metadata["total_inference_time_s"] = round(elapsed, 1)
        metadata["avg_time_per_question_s"] = round(elapsed / len(results), 2) if results else 0

        save_checkpoint(output_path, metadata, scores, results)
        print(f"Saved: {output_path}")

        # Print summary
        if ds_type == "mcq":
            acc = scores.get("accuracy", 0)
            partial = scores.get("partial_credit_accuracy", acc)
            print(f"Accuracy: {acc:.1%} ({scores.get('correct', 0)}/{scores.get('total', 0)})")
            if partial != acc:
                print(f"Partial credit: {partial:.1%}")
            summary.append(f"  {ds_name}: {acc:.1%} (partial: {partial:.1%})")
        else:
            mean_score = scores.get("mean_judge_score")
            if mean_score is not None:
                print(f"Mean judge score: {mean_score}/5 (n={scores.get('n_judged', 0)})")
                summary.append(f"  {ds_name}: {mean_score}/5")
            else:
                print(f"Responses saved (no judge scoring)")
                summary.append(f"  {ds_name}: {len(results)} responses saved")

    # Final summary
    print(f"\n{'='*60}")
    print(f"SUMMARY — {args.model}")
    print(f"{'='*60}")
    for line in summary:
        print(line)


if __name__ == "__main__":
    main()
