#!/usr/bin/env python3
"""Re-run LLM-as-judge scoring on saved open-ended result files.

Usage:
    python rescore_open.py [paths...]

If no paths are given, rescores all open-ended result JSONs under evaluation/results/.
Skips rows that already have judge_weighted_score. Rewrites files in-place.
"""

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from scoring import JUDGE_DIMENSIONS, _compute_weighted_score, create_judge_client, judge_response

OPEN_DATASETS = {"kenya_vignettes", "afrimedqa_saq", "whb_stumps"}
CHECKPOINT_EVERY = 10
MAX_WORKERS = 20


def _agg_scores(results: list) -> dict:
    judgments = []
    n_failed = 0
    for r in results:
        ws = r.get("judge_weighted_score")
        if ws is not None:
            j = {dim: r.get("judge_scores", {}).get(dim) for dim in JUDGE_DIMENSIONS}
            j["weighted_score"] = ws
            judgments.append(j)
        elif r.get("model_response"):
            n_failed += 1

    scores = {"n_judged": len(judgments), "n_failed": n_failed,
              "dimension_weights": dict(JUDGE_DIMENSIONS)}
    if judgments:
        scores["mean_weighted_score"] = round(
            sum(j["weighted_score"] for j in judgments) / len(judgments), 2)
        for dim in JUDGE_DIMENSIONS:
            vals = [j[dim] for j in judgments if j.get(dim) is not None]
            if vals:
                scores[f"mean_{dim}"] = round(sum(vals) / len(vals), 2)
    return scores


def is_open_result(data: dict) -> bool:
    meta = data.get("metadata", {})
    dataset = meta.get("dataset", "")
    dataset_type = meta.get("dataset_type", "")
    return dataset in OPEN_DATASETS or dataset_type == "open"


def rescore_file(path: Path, judge_client, judge_model: str, dry_run: bool) -> dict | None:
    data = json.loads(path.read_text())

    if not is_open_result(data):
        return None

    results = data.get("results", [])
    if not results:
        return None

    unjudged = [r for r in results if r.get("judge_weighted_score") is None and r.get("model_response")]
    if not unjudged:
        return None  # already fully judged

    if dry_run:
        return {"path": str(path), "unjudged": len(unjudged), "total": len(results)}

    judged = 0
    failed = 0

    # Collect indices that need judging
    todo = [
        (i, r) for i, r in enumerate(results)
        if r.get("judge_weighted_score") is None
        and r.get("model_response")
        and r.get("reference")
    ]

    def _judge_one(idx_row):
        idx, r = idx_row
        judgment = judge_response(
            r.get("question", ""), r["model_response"], r["reference"],
            judge_client, judge_model,
        )
        return idx, judgment

    completed = 0
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {pool.submit(_judge_one, item): item for item in todo}
        for future in as_completed(futures):
            idx, judgment = future.result()
            r = results[idx]
            if judgment and judgment.get("weighted_score") is not None:
                r["judge_scores"] = {dim: judgment.get(dim) for dim in JUDGE_DIMENSIONS}
                r["judge_weighted_score"] = judgment["weighted_score"]
                r["judge_justification"] = judgment.get("justification")
                judged += 1
            else:
                failed += 1
            completed += 1
            if completed % CHECKPOINT_EVERY == 0:
                data["aggregate_scores"] = _agg_scores(results)
                path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
                print(f"    checkpoint {completed}/{len(todo)}")

    data["aggregate_scores"] = _agg_scores(results)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")

    return {"path": str(path), "judged": judged, "failed": failed, "total": len(results),
            "mean_score": data["aggregate_scores"].get("mean_weighted_score")}


def find_open_files(roots: list[Path]) -> list[Path]:
    files = []
    for root in roots:
        if root.is_file():
            files.append(root)
        else:
            for f in sorted(root.rglob("*.json")):
                if "build/" in str(f) or "__pycache__" in str(f):
                    continue
                files.append(f)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Preview without writing")
    parser.add_argument("--judge-model", default=None, help="Override judge model")
    parser.add_argument("paths", nargs="*", help="Files or directories to rescore")
    args = parser.parse_args()

    judge_client, judge_model = create_judge_client()
    if args.judge_model:
        judge_model = args.judge_model
    if judge_client is None:
        print("ERROR: no OPENAI_API_KEY found.")
        sys.exit(1)
    print(f"Judge model: {judge_model}")

    results_dir = Path(__file__).parent / "results"
    roots = [Path(p) for p in args.paths] if args.paths else [results_dir]
    files = find_open_files(roots)
    print(f"Scanning {len(files)} JSON files...\n")

    updated = []
    for f in files:
        try:
            summary = rescore_file(f, judge_client, judge_model, dry_run=args.dry_run)
        except Exception as e:
            print(f"  ERROR {f}: {e}")
            continue
        if summary:
            updated.append(summary)
            label = "[DRY RUN] " if args.dry_run else ""
            if args.dry_run:
                print(f"{label}{summary['path']}: {summary['unjudged']} unjudged / {summary['total']} total")
            else:
                print(f"UPDATED {summary['path']}: judged={summary['judged']} failed={summary['failed']} mean={summary.get('mean_score')}")

    if not updated:
        print("No files needed rescoring.")
    else:
        action = "would be" if args.dry_run else "were"
        print(f"\n{len(updated)} file(s) {action} updated.")


if __name__ == "__main__":
    main()
