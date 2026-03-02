"""
Retroactively add LLM-as-judge scores to existing open-ended result JSONs.

Usage:
  python rescore.py results/gemma3n-e4b_kenya_vignettes_*.json
  python rescore.py results/*_kenya_vignettes_*.json results/*_whb_stumps_*.json
"""

import argparse
import json
import sys

from tqdm import tqdm

from scoring import create_judge_client, judge_response


def rescore_file(filepath: str, client, model: str):
    with open(filepath) as f:
        data = json.load(f)

    if data["metadata"].get("dataset_type") != "open":
        print(f"SKIP (not open-ended): {filepath}")
        return

    results = data["results"]
    judge_scores = []

    for r in tqdm(results, desc=filepath):
        if r.get("judge_score") is not None:
            judge_scores.append(r["judge_score"])
            continue

        reference = r.get("reference", "")
        if not reference:
            continue

        judgment = judge_response(r["question"], r["model_response"], reference, client, model)
        if judgment:
            r["judge_score"] = judgment.get("score")
            r["judge_justification"] = judgment.get("justification")
            if judgment.get("score") is not None:
                judge_scores.append(judgment["score"])

    # Update aggregate scores
    if judge_scores:
        data["aggregate_scores"] = {
            "mean_judge_score": round(sum(judge_scores) / len(judge_scores), 2),
            "judge_scores_distribution": {i: judge_scores.count(i) for i in range(1, 6)},
            "n_judged": len(judge_scores),
        }

    with open(filepath, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    mean = data["aggregate_scores"].get("mean_judge_score", "N/A")
    print(f"Done: {filepath} — mean judge score: {mean}/5 (n={len(judge_scores)})")


def main():
    parser = argparse.ArgumentParser(description="Retroactively add judge scores to result JSONs")
    parser.add_argument("files", nargs="+", help="Result JSON files to rescore")
    parser.add_argument("--judge-model", default="gemini-3-flash-preview", help="Gemini model for judging")
    args = parser.parse_args()

    client, model = create_judge_client(args.judge_model)
    if client is None:
        print("ERROR: No GEMINI_API_KEY found. Set it via environment variable.")
        sys.exit(1)

    for filepath in args.files:
        rescore_file(filepath, client, model)


if __name__ == "__main__":
    main()
