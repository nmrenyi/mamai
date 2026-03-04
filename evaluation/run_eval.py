"""
Batch evaluation pipeline for medical QA benchmarks.

Usage:
  python run_eval.py --model gemma3n-e4b --datasets afrimedqa_mcq --max-questions 5
  python run_eval.py --model gemma3n-e4b --datasets all --judge
  python run_eval.py --model gemma3n-e2b --model-dir /mloscratch/users/$USER/models --datasets all
  python run_eval.py --model gpt-5 --datasets all --judge  # OpenAI API (needs OPENAI_API_KEY)
"""

import argparse
import json
import os
import time
from datetime import datetime, timezone

import pandas as pd
from tqdm import tqdm

from inference import load_model
from prompts import (TEMPERATURE, TOP_P, TOP_K, N_CTX, PROMPT_VERSION,
                     build_mcq_prompt, build_mcq_messages, build_open_prompt, build_open_messages,
                     build_rag_mcq_prompt, build_rag_mcq_messages, build_rag_open_prompt, build_rag_open_messages)
from scoring import JUDGE_DIMENSIONS, _parse_answer_set, create_judge_client, extract_letters, judge_response, score_mcq

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
            output_path=None, metadata=None, rag_contexts=None, resume_results=None):
    """Run MCQ evaluation: inference + letter extraction + accuracy."""
    if max_questions:
        df = df.head(max_questions)

    # Resume from checkpoint: reuse existing results and skip those rows
    n_skip = len(resume_results) if resume_results else 0
    results = list(resume_results) if resume_results else []
    predictions = [r["extracted_answer"] for r in results]
    ground_truth = [r["ground_truth"] for r in results]
    if n_skip:
        print(f"  Resuming from checkpoint: skipping {n_skip} already-completed rows")

    for i, (_, row) in enumerate(tqdm(df.iterrows(), total=len(df), desc="MCQ inference", initial=n_skip), 1):
        if i <= n_skip:
            continue
        if pd.isna(row[question_col]) or pd.isna(row[options_col]) or pd.isna(row[answer_col]):
            print(f"  Skipping row {i}: missing question/options/answer")
            continue

        question = str(row[question_col])
        options = str(row[options_col])
        correct = str(row[answer_col]).strip()

        # RAG context injection
        context_str = ""
        if rag_contexts and (i - 1) < len(rag_contexts):
            chunks = rag_contexts[i - 1].get("chunks", [])
            context_str = "\n\n".join(chunks)

        t0 = time.time()
        try:
            if hasattr(model, 'is_api') and model.is_api:
                if context_str:
                    messages = build_rag_mcq_messages(question, options, context_str)
                else:
                    messages = build_mcq_messages(question, options)
                response = model.generate(messages, max_tokens=max_tokens)
            else:
                if context_str:
                    prompt = build_rag_mcq_prompt(question, options, context_str)
                else:
                    prompt = build_mcq_prompt(question, options)
                response = model.generate(prompt, max_tokens=max_tokens)
        except Exception as e:
            print(f"  ERROR row {i}: generate() failed: {e}")
            continue
        elapsed = time.time() - t0

        extracted_set = extract_letters(response)
        extracted = ",".join(sorted(extracted_set)) if extracted_set else ""
        predictions.append(extracted)
        ground_truth.append(correct)

        results.append({
            "question": question,
            "options": options,
            "ground_truth": correct,
            "rag_context": context_str[:200] + "..." if context_str else "",
            "model_response": response,
            "extracted_answer": extracted,
            "extracted_answers": sorted(extracted_set),
            "correct": extracted_set == _parse_answer_set(correct),
            "inference_time_s": round(elapsed, 2),
        })

        if output_path and i % CHECKPOINT_INTERVAL == 0:
            scores = score_mcq(predictions, ground_truth)
            save_checkpoint(output_path, metadata or {}, scores, results)
            print(f"  Checkpoint saved at {i}/{len(df)}")

    scores = score_mcq(predictions, ground_truth)
    return results, scores


def _open_scores(judgments, n_failed=0):
    """Compute aggregate judge scores across all dimensions.

    Args:
        judgments: list of judgment dicts, each with per-dimension scores and weighted_score.
        n_failed: number of judge API calls that failed or returned unparseable results.
    """
    if not judgments and not n_failed:
        return {}

    scores = {}
    # Per-dimension aggregates
    for dim in JUDGE_DIMENSIONS:
        dim_scores = [j[dim] for j in judgments if j.get(dim) is not None]
        if dim_scores:
            scores[f"mean_{dim}"] = round(sum(dim_scores) / len(dim_scores), 2)
            scores[f"{dim}_distribution"] = {i: dim_scores.count(i) for i in range(1, 6)}

    # Weighted aggregate
    weighted = [j["weighted_score"] for j in judgments if j.get("weighted_score") is not None]
    if weighted:
        scores["mean_weighted_score"] = round(sum(weighted) / len(weighted), 2)

    scores["n_judged"] = len(judgments)
    scores["n_failed"] = n_failed
    scores["dimension_weights"] = dict(JUDGE_DIMENSIONS)
    return scores


def run_open(model, df, question_col, reference_col, max_tokens, max_questions, judge_client, judge_model,
             output_path=None, metadata=None, rag_contexts=None, resume_results=None):
    """Run open-ended evaluation: inference + optional LLM-as-judge scoring."""
    if max_questions:
        df = df.head(max_questions)

    # Resume from checkpoint: reuse existing results and skip those rows
    n_skip = len(resume_results) if resume_results else 0
    results = list(resume_results) if resume_results else []
    judgments = []
    n_judge_failed = 0
    # Reconstruct judgments from resumed results
    for r in results:
        if r.get("judge_weighted_score") is not None:
            j = {dim: r["judge_scores"].get(dim) for dim in JUDGE_DIMENSIONS}
            j["weighted_score"] = r["judge_weighted_score"]
            judgments.append(j)
    if n_skip:
        print(f"  Resuming from checkpoint: skipping {n_skip} already-completed rows")

    for i, (_, row) in enumerate(tqdm(df.iterrows(), total=len(df), desc="Open inference", initial=n_skip), 1):
        if i <= n_skip:
            continue
        if pd.isna(row[question_col]):
            print(f"  Skipping row {i}: missing question")
            continue

        question = str(row[question_col])
        reference = str(row[reference_col]) if reference_col and reference_col in row.index and pd.notna(row[reference_col]) else ""

        # RAG context injection
        context_str = ""
        if rag_contexts and (i - 1) < len(rag_contexts):
            chunks = rag_contexts[i - 1].get("chunks", [])
            context_str = "\n\n".join(chunks)

        t0 = time.time()
        try:
            if hasattr(model, 'is_api') and model.is_api:
                if context_str:
                    messages = build_rag_open_messages(question, context_str)
                else:
                    messages = build_open_messages(question)
                response = model.generate(messages, max_tokens=max_tokens)
            else:
                if context_str:
                    prompt = build_rag_open_prompt(question, context_str)
                else:
                    prompt = build_open_prompt(question)
                response = model.generate(prompt, max_tokens=max_tokens)
        except Exception as e:
            print(f"  ERROR row {i}: generate() failed: {e}")
            continue
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
            if judgment and judgment.get("weighted_score") is not None:
                result["judge_scores"] = {dim: judgment.get(dim) for dim in JUDGE_DIMENSIONS}
                result["judge_weighted_score"] = judgment["weighted_score"]
                result["judge_justification"] = judgment.get("justification")
                judgments.append(judgment)
            else:
                n_judge_failed += 1

        results.append(result)

        if output_path and i % CHECKPOINT_INTERVAL == 0:
            save_checkpoint(output_path, metadata or {}, _open_scores(judgments, n_judge_failed), results)
            print(f"  Checkpoint saved at {i}/{len(df)}")

    return results, _open_scores(judgments, n_judge_failed)


def save_checkpoint(output_path, metadata, scores, results):
    """Save current results to a JSON checkpoint file."""
    data = {"metadata": metadata, "aggregate_scores": scores, "results": results}
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser(description="Medical QA Evaluation Pipeline")
    parser.add_argument("--model", required=True, help="Model name (e.g., gemma3n-e4b, gemma3n-e2b)")
    parser.add_argument("--model-dir", default="models", help="Directory containing model files (not needed for API models)")
    parser.add_argument("--datasets", required=True, help="Comma-separated dataset names, or 'all'")
    parser.add_argument("--output-dir", default="results", help="Directory for output JSON files")
    parser.add_argument("--max-tokens", type=int, default=2048, help="Max tokens to generate")
    parser.add_argument("--max-questions", type=int, default=None, help="Limit questions per dataset (for debugging)")
    parser.add_argument("--judge", action="store_true", help="Enable LLM-as-judge for open-ended datasets")
    parser.add_argument("--judge-model", default="gpt-5.2", help="OpenAI model for judging")
    parser.add_argument("--n-gpu-layers", type=int, default=None, help="GPU layers for GGUF (-1 = all, 0 = CPU, default: auto-detect)")
    parser.add_argument("--data-dir", default="data", help="Directory containing dataset TSV files")
    parser.add_argument("--rag", default=None, help="Path to pre-computed RAG contexts dir (from precompute_retrieval.py)")
    parser.add_argument("--resume", default=None, help="Path to previous run dir to resume incomplete datasets from")
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
            print("WARNING: --judge requested but no OPENAI_API_KEY found. Skipping judge scoring.")

    # Run evaluation for each dataset
    run_timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    run_dir = os.path.join(args.output_dir, args.model, run_timestamp)
    os.makedirs(run_dir, exist_ok=True)

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

        output_path = os.path.join(run_dir, f"{ds_name}.json")

        # Load pre-computed RAG contexts if available
        rag_contexts = None
        if args.rag:
            rag_path = os.path.join(args.rag, f"{ds_name}.json")
            if os.path.exists(rag_path):
                with open(rag_path) as f:
                    rag_data = json.load(f)
                rag_contexts = rag_data["retrievals"]
                print(f"RAG contexts loaded: {len(rag_contexts)} entries (top-{rag_data['config']['top_k']})")
            else:
                print(f"WARNING: --rag specified but {rag_path} not found. Running without RAG.")

        metadata = {
            "model": args.model,
            "model_dir": args.model_dir,
            "dataset": ds_name,
            "dataset_type": ds_type,
            "n_questions": min(len(df), args.max_questions or len(df)),
            "timestamp": run_timestamp,
            "prompt_version": PROMPT_VERSION,
            "rag": rag_contexts is not None,
            "generation_params": {
                "temperature": TEMPERATURE,
                "top_p": TOP_P,
                "top_k": TOP_K,
                "n_ctx": N_CTX,
                "max_tokens": args.max_tokens,
            },
        }

        # Load previous checkpoint for resume
        resume_results = None
        if args.resume:
            resume_path = os.path.join(args.resume, f"{ds_name}.json")
            if os.path.exists(resume_path):
                with open(resume_path) as f:
                    prev = json.load(f)
                prev_results = prev.get("results", [])
                expected = min(len(df), args.max_questions or len(df))
                if len(prev_results) >= expected:
                    print(f"  Already complete ({len(prev_results)}/{expected}), skipping")
                    # Copy the completed file to new run dir
                    save_checkpoint(output_path, prev.get("metadata", metadata),
                                    prev.get("aggregate_scores", {}), prev_results)
                    scores = prev.get("aggregate_scores", {})
                    results = prev_results
                    # Print summary and continue to next dataset
                    if ds_type == "mcq":
                        acc = scores.get("accuracy", 0)
                        partial = scores.get("partial_credit_accuracy", acc)
                        summary.append(f"  {ds_name}: {acc:.1%} (partial: {partial:.1%}) [resumed]")
                    else:
                        mean_score = scores.get("mean_weighted_score")
                        if mean_score is not None:
                            summary.append(f"  {ds_name}: {mean_score}/5 [resumed]")
                        else:
                            summary.append(f"  {ds_name}: {len(results)} responses saved [resumed]")
                    continue
                else:
                    resume_results = prev_results
                    print(f"  Resuming: {len(resume_results)}/{expected} results from checkpoint")

        t0 = time.time()
        if ds_type == "mcq":
            results, scores = run_mcq(model, df, q_col, opt_col, ans_col, args.max_tokens, args.max_questions,
                                      output_path, metadata, rag_contexts=rag_contexts,
                                      resume_results=resume_results)
        else:
            results, scores = run_open(model, df, q_col, ref_col, args.max_tokens, args.max_questions,
                                       judge_client, judge_model, output_path, metadata, rag_contexts=rag_contexts,
                                       resume_results=resume_results)

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
            mean_score = scores.get("mean_weighted_score")
            if mean_score is not None:
                print(f"Mean weighted score: {mean_score}/5 (n={scores.get('n_judged', 0)})")
                for dim in JUDGE_DIMENSIONS:
                    dim_mean = scores.get(f"mean_{dim}")
                    if dim_mean is not None:
                        print(f"  {dim}: {dim_mean}/5")
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
