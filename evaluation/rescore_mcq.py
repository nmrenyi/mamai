#!/usr/bin/env python3
"""Re-run MCQ extraction on saved result files using the current extract_letters().

Usage:
    python rescore_mcq.py [--dry-run] [paths...]

If no paths are given, rescores all MCQ result JSONs under evaluation/results/.
Use --dry-run to preview changes without writing.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Add evaluation/ to path so we can import scoring
sys.path.insert(0, str(Path(__file__).parent))
from scoring import extract_letters, score_mcq

MCQ_DATASETS = {"afrimedqa_mcq", "medmcqa_mcq", "medqa_usmle"}


def is_mcq_result(data: dict) -> bool:
    meta = data.get("metadata", {})
    dataset = meta.get("dataset", "")
    dataset_type = meta.get("dataset_type", "")
    return dataset in MCQ_DATASETS or dataset_type == "mcq"


def rescore_file(path: Path, dry_run: bool) -> dict | None:
    """Re-extract answers and recompute aggregates. Returns change summary or None if no changes."""
    data = json.loads(path.read_text())

    if not is_mcq_result(data):
        return None

    results = data.get("results", [])
    if not results:
        return None

    changed = 0
    new_extracted = []
    new_extracted_sets = []

    for r in results:
        response = r.get("model_response", "")
        old_answer = r.get("extracted_answer", "")

        letters = extract_letters(response)
        new_answer = ",".join(sorted(letters)) if letters else ""
        new_extracted.append(new_answer)
        new_extracted_sets.append(sorted(letters))

        if new_answer != old_answer:
            changed += 1

    if changed == 0:
        return None  # nothing to do

    # Recompute aggregate scores
    ground_truths = [r["ground_truth"] for r in results]
    new_scores = score_mcq(new_extracted, ground_truths)

    old_accuracy = data["aggregate_scores"].get("accuracy", 0.0)
    old_partial = data["aggregate_scores"].get("partial_credit_accuracy", 0.0)
    new_accuracy = new_scores["accuracy"]
    new_partial = new_scores["partial_credit_accuracy"]

    summary = {
        "path": str(path),
        "questions_changed": changed,
        "old_accuracy": old_accuracy,
        "new_accuracy": new_accuracy,
        "old_partial": old_partial,
        "new_partial": new_partial,
    }

    if not dry_run:
        # Update per-question fields
        for r, new_ans, new_ans_list in zip(results, new_extracted, new_extracted_sets):
            r["extracted_answer"] = new_ans
            r["extracted_answers"] = new_ans_list
            r["correct"] = new_scores["per_question"][results.index(r)]

        # Update aggregate
        data["aggregate_scores"]["accuracy"] = new_accuracy
        data["aggregate_scores"]["correct"] = new_scores["correct"]
        data["aggregate_scores"]["partial_credit_accuracy"] = new_partial
        data["aggregate_scores"]["per_question"] = new_scores["per_question"]
        data["aggregate_scores"]["per_question_partial"] = new_scores["per_question_partial"]

        path.write_text(json.dumps(data, indent=2) + "\n")

    return summary


def find_mcq_files(roots: list[Path]) -> list[Path]:
    files = []
    for root in roots:
        if root.is_file():
            files.append(root)
        else:
            for f in sorted(root.rglob("*.json")):
                # Skip build artifacts and non-result files
                if "build/" in str(f) or "__pycache__" in str(f):
                    continue
                files.append(f)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without writing")
    parser.add_argument("paths", nargs="*", help="Files or directories to rescore")
    args = parser.parse_args()

    results_dir = Path(__file__).parent / "results"
    roots = [Path(p) for p in args.paths] if args.paths else [results_dir]

    files = find_mcq_files(roots)
    print(f"Scanning {len(files)} JSON files...\n")

    changed_files = []
    for f in files:
        try:
            summary = rescore_file(f, dry_run=args.dry_run)
        except Exception as e:
            print(f"  ERROR {f}: {e}")
            continue
        if summary:
            changed_files.append(summary)
            label = "[DRY RUN] " if args.dry_run else ""
            print(
                f"{label}UPDATED {summary['path']}\n"
                f"  Questions changed: {summary['questions_changed']}\n"
                f"  Accuracy:         {summary['old_accuracy']:.4f} → {summary['new_accuracy']:.4f}\n"
                f"  Partial credit:   {summary['old_partial']:.4f} → {summary['new_partial']:.4f}\n"
            )

    if not changed_files:
        print("No files needed rescoring.")
    else:
        action = "would be" if args.dry_run else "were"
        print(f"\n{len(changed_files)} file(s) {action} updated.")


if __name__ == "__main__":
    main()
