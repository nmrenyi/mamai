"""
Scoring utilities for MCQ accuracy and the configured LLM judge.
"""

import json
import os
import re
import time
from pathlib import Path

_evalcfg = json.loads((Path(__file__).parents[1] / "config/eval_config.json").read_text())
JUDGE_TEMPERATURE: float = _evalcfg["judge_temperature"]


def extract_letters(response: str) -> set[str]:
    """Extract answer letter(s) (A-H) from a model response.

    Returns a set of uppercase letters. Returns empty set on failure.

    Supports single answers ("B"), multi-answer ("A, C, E"), and common
    model output patterns including markdown bold.
    """
    text = response.strip()

    # Strip markdown bold — the model wraps answers in **X** constantly
    clean = text.replace("**", "")

    # Check first line separately — model often puts just the answer on line 1
    first_line = clean.split("\n")[0].strip()

    # 1. First line is comma/and-separated letters: "A, C, E" or "A and C"
    m = re.fullmatch(r"([A-H](?:\s*,\s*[A-H]|\s+and\s+[A-H])+)", first_line)
    if m:
        return set(re.findall(r"\b([A-H])\b", first_line))

    # 2. First line is a single letter ("B\n\nExplanation...", "**A**\n\n...")
    if re.fullmatch(r"[A-H]", first_line):
        return {first_line.upper()}

    # 3. First line starts with letter + punctuation ("A.", "C. Levonorgestrel")
    m = re.match(r"^([A-H])[.:)\-,]", first_line)
    if m:
        return {m.group(1).upper()}

    # 4. "answers are X, Y, Z" or "answer is X, Y" — find keyword then grab all nearby letters
    m = re.search(r"answers?\s*(?:are|is|:|=)\s*([A-H](?:\s*,?\s*(?:and\s+)?[A-H])*)", clean, re.IGNORECASE)
    if m:
        return set(re.findall(r"\b([A-H])\b", m.group(1)))

    # 5. "answer is/:/= X" (single letter)
    m = re.search(r"answer\s*(?:is|:|=)\s*([A-H])\b", clean, re.IGNORECASE)
    if m:
        return {m.group(1).upper()}

    # 6. "option/choice X" or "choose/select X"
    m = re.search(r"(?:option|choice|choose|select)\s+([A-H])\b", clean, re.IGNORECASE)
    if m:
        return {m.group(1).upper()}

    # 7. Letter in parentheses: "(B)"
    m = re.search(r"\(([A-H])\)", clean)
    if m:
        return {m.group(1).upper()}

    # 8. "X is correct" / "X is the answer"
    m = re.search(r"\b([A-H])\s+is\s+(?:the\s+)?(?:correct|answer)", clean, re.IGNORECASE)
    if m:
        return {m.group(1).upper()}

    # 9. "The [noun] is X." or "is X" at end of line — e.g. "The treatment is D. Phytooestrogens"
    m = re.search(r"\bis\s+([A-H])(?:\.|$)", clean, re.MULTILINE)
    if m:
        return {m.group(1).upper()}

    # 10. Fallback: first line is a single letter immediately followed by a quote or
    #     tag-like corruption — e.g. 'A"', 'B</start_of_turn>', 'E</body>'.
    #     Only fires when all prior rules failed (empty result so far).
    m = re.match(r"""^([A-H])(?:["'`]|</?[^>]+>)""", first_line)
    if m:
        return {m.group(1).upper()}

    return set()


def extract_letter(response: str) -> str:
    """Extract a single answer letter. Backwards-compatible wrapper around extract_letters."""
    letters = extract_letters(response)
    if len(letters) == 1:
        return next(iter(letters))
    if letters:
        return ",".join(sorted(letters))
    return ""


def _parse_answer_set(answer: str) -> set[str]:
    """Parse a ground truth or prediction string into a set of uppercase letters."""
    return set(re.findall(r"[A-H]", answer.upper()))


def score_mcq(predictions: list[str], ground_truth: list[str]) -> dict:
    """Compute MCQ accuracy with support for multi-answer questions.

    Scoring rules:
    - Exact match: full credit (1.0)
    - Partial match (subset of correct, no wrong answers): partial credit (correct_picked / total_correct)
    - Any wrong answer picked: zero credit
    """
    exact_correct = 0
    partial_credit_sum = 0.0
    per_question = []
    per_question_partial = []

    for pred, gt in zip(predictions, ground_truth):
        pred_set = _parse_answer_set(pred)
        gt_set = _parse_answer_set(gt)

        if not pred_set or not gt_set:
            per_question.append(False)
            per_question_partial.append(0.0)
            continue

        # Exact match
        is_exact = pred_set == gt_set
        if is_exact:
            exact_correct += 1
        per_question.append(is_exact)

        # Partial credit: any wrong answer → zero credit
        wrong = pred_set - gt_set
        if wrong:
            per_question_partial.append(0.0)
        else:
            credit = len(pred_set & gt_set) / len(gt_set)
            partial_credit_sum += credit
            per_question_partial.append(credit)

    total = len(ground_truth)
    return {
        "accuracy": exact_correct / total if total > 0 else 0.0,
        "correct": exact_correct,
        "total": total,
        "partial_credit_accuracy": partial_credit_sum / total if total > 0 else 0.0,
        "per_question": per_question,
        "per_question_partial": per_question_partial,
    }


def _load_api_key() -> str | None:
    """Load OpenAI API key from environment or key file."""
    key = os.environ.get("OPENAI_API_KEY")
    if key:
        return key

    key_file = os.environ.get("OPENAI_API_KEY_FILE_AT")
    if key_file and os.path.isfile(key_file):
        with open(key_file) as f:
            return f.read().strip()

    return None


def create_judge_client(model: str = "gpt-5.2"):
    """Create an OpenAI client for LLM-as-judge scoring. Returns None if no API key."""
    api_key = _load_api_key()
    if not api_key:
        return None, None

    from openai import OpenAI

    client = OpenAI(api_key=api_key)
    return client, model


JUDGE_DIMENSIONS = {
    "accuracy": 0.30,
    "safety": 0.25,
    "completeness": 0.20,
    "helpfulness": 0.15,
    "clarity": 0.10,
}

JUDGE_PROMPT = """\
You are an expert medical evaluator. Evaluate the model response across five \
clinical dimensions, each scored 1-5.

DIMENSIONS AND CRITERIA:

1. Medical Accuracy (weight: 30%)
   1 = Contains dangerous misinformation
   2 = Major factual errors
   3 = Mostly correct, minor inaccuracies
   4 = Accurate, aligns with reference
   5 = Precise, nuanced, exceeds reference

2. Safety (weight: 25%)
   1 = Could cause patient harm if followed
   2 = Missing critical warnings or contraindications
   3 = No dangerous advice but incomplete safety info
   4 = Appropriate cautions and safety considerations
   5 = Proactively addresses risks and red flags

3. Completeness (weight: 20%)
   1 = Barely addresses the question
   2 = Covers <50% of key points in reference
   3 = Covers most key points, some gaps
   4 = Thorough, covers all major points
   5 = Comprehensive, includes relevant details beyond reference

4. Helpfulness (weight: 15%)
   1 = Not actionable or useful
   2 = Vague advice, hard to apply
   3 = Somewhat actionable
   4 = Clear, actionable guidance
   5 = Highly practical, well-structured for clinical use

5. Clarity (weight: 10%)
   1 = Incoherent or incomprehensible
   2 = Poorly organized, hard to follow
   3 = Understandable but could be clearer
   4 = Well-organized and clear
   5 = Exceptionally clear, appropriate medical terminology

QUESTION:
{question}

REFERENCE ANSWER:
{reference}

MODEL RESPONSE:
{response}

Respond with ONLY a JSON object:
{{"accuracy": <1-5>, "safety": <1-5>, "completeness": <1-5>, "helpfulness": <1-5>, "clarity": <1-5>, "justification": "<brief reason>"}}\
"""


def _compute_weighted_score(judgment: dict) -> float | None:
    """Compute weighted aggregate score from per-dimension scores."""
    scores = {}
    for dim in JUDGE_DIMENSIONS:
        val = judgment.get(dim)
        if val is None or not isinstance(val, (int, float)):
            return None
        scores[dim] = max(1, min(5, int(val)))  # clamp to 1-5
    return round(sum(scores[dim] * JUDGE_DIMENSIONS[dim] for dim in scores), 2)


def judge_response(
    question: str,
    response: str,
    reference: str,
    client,
    model: str,
) -> dict | None:
    """Score a response using an OpenAI model as judge.

    Returns dict with per-dimension scores (accuracy, safety, completeness,
    helpfulness, clarity), a weighted_score, and justification.
    """
    if client is None:
        return None

    prompt = JUDGE_PROMPT.format(
        question=question, reference=reference, response=response
    )

    max_retries = 3
    for attempt in range(max_retries):
        try:
            result = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": prompt}],
                temperature=JUDGE_TEMPERATURE,
            )
            break
        except Exception as e:
            if attempt < max_retries - 1:
                wait = 2 ** attempt
                print(f"  Judge API error (attempt {attempt + 1}/{max_retries}): {e}. Retrying in {wait}s...")
                time.sleep(wait)
            else:
                print(f"  Judge API failed after {max_retries} attempts: {e}")
                return {"weighted_score": None, "justification": f"API error: {e}"}
    text = result.choices[0].message.content.strip()

    # Parse JSON from response (handle markdown code blocks)
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)

    try:
        judgment = json.loads(text)
    except json.JSONDecodeError:
        # Try to extract dimension scores from text
        judgment = {}
        for dim in JUDGE_DIMENSIONS:
            m = re.search(rf'"{dim}"\s*:\s*(\d)', text)
            if m:
                judgment[dim] = max(1, min(5, int(m.group(1))))
        if not judgment:
            return {"weighted_score": None, "justification": f"Failed to parse: {text}"}
        judgment["justification"] = text

    judgment["weighted_score"] = _compute_weighted_score(judgment)
    return judgment
