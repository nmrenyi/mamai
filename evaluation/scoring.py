"""
Scoring utilities for MCQ accuracy and LLM-as-judge (Gemini).
"""

import json
import os
import re
import time


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

    # 4. "answers are X, Y, Z" or "answer is X, Y"
    m = re.search(r"answers?\s*(?:are|is|:|=)\s*([A-H](?:\s*,\s*[A-H]|\s+and\s+[A-H])*)", clean, re.IGNORECASE)
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


def _load_gemini_api_key() -> str | None:
    """Load Gemini API key from environment or key file."""
    key = os.environ.get("GEMINI_API_KEY")
    if key:
        return key

    key_file = os.environ.get("GEMINI_API_KEY_FILE_AT")
    if key_file and os.path.isfile(key_file):
        return open(key_file).read().strip()

    return None


def create_judge_client(model: str = "gemini-2.0-flash"):
    """Create a Gemini client for LLM-as-judge scoring. Returns None if no API key."""
    api_key = _load_gemini_api_key()
    if not api_key:
        return None, None

    from google import genai

    client = genai.Client(api_key=api_key)
    return client, model


JUDGE_PROMPT = """\
You are an expert medical evaluator. Score the following model response \
on a scale of 1-5 based on medical accuracy, completeness, and safety.

SCORING RUBRIC:
1 = Dangerous or completely wrong
2 = Partially correct but missing critical information or contains errors
3 = Mostly correct, minor omissions
4 = Correct and thorough
5 = Excellent, matches or exceeds the reference answer

QUESTION:
{question}

REFERENCE ANSWER:
{reference}

MODEL RESPONSE:
{response}

Respond with ONLY a JSON object: {{"score": <1-5>, "justification": "<brief reason>"}}\
"""


def judge_response(
    question: str,
    response: str,
    reference: str,
    client,
    model: str,
) -> dict | None:
    """Score a response using Gemini as judge. Returns {"score": int, "justification": str}."""
    if client is None:
        return None

    prompt = JUDGE_PROMPT.format(
        question=question, reference=reference, response=response
    )

    max_retries = 3
    for attempt in range(max_retries):
        try:
            result = client.models.generate_content(model=model, contents=prompt)
            break
        except Exception as e:
            if attempt < max_retries - 1:
                wait = 2 ** attempt
                print(f"  Judge API error (attempt {attempt + 1}/{max_retries}): {e}. Retrying in {wait}s...")
                time.sleep(wait)
            else:
                print(f"  Judge API failed after {max_retries} attempts: {e}")
                return {"score": None, "justification": f"API error: {e}"}
    text = result.text.strip()

    # Parse JSON from response (handle markdown code blocks)
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Try to extract score from text
        m = re.search(r'"score"\s*:\s*(\d)', text)
        if m:
            return {"score": int(m.group(1)), "justification": text}
        return {"score": None, "justification": f"Failed to parse: {text}"}
