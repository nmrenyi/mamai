"""Tests for score_mcq() in scoring.py.

The partial credit logic is non-obvious and a regression here would corrupt
all reported accuracy numbers without any obvious error signal.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
from scoring import score_mcq


# ── Single-answer questions ───────────────────────────────────────────────────

def test_single_exact_correct():
    r = score_mcq(["A"], ["A"])
    assert r["accuracy"] == 1.0
    assert r["correct"] == 1
    assert r["partial_credit_accuracy"] == 1.0


def test_single_wrong():
    r = score_mcq(["B"], ["A"])
    assert r["accuracy"] == 0.0
    assert r["correct"] == 0
    assert r["partial_credit_accuracy"] == 0.0


def test_single_empty_prediction():
    r = score_mcq([""], ["A"])
    assert r["accuracy"] == 0.0
    assert r["partial_credit_accuracy"] == 0.0


def test_single_multiple_questions():
    r = score_mcq(["A", "B", "C"], ["A", "B", "D"])
    assert r["correct"] == 2
    assert r["total"] == 3
    assert abs(r["accuracy"] - 2 / 3) < 1e-9


# ── Multi-answer questions ────────────────────────────────────────────────────

def test_multi_exact_correct():
    r = score_mcq(["A,B,C"], ["A,B,C"])
    assert r["accuracy"] == 1.0
    assert r["partial_credit_accuracy"] == 1.0


def test_multi_partial_no_wrong():
    # Predicted A,B out of correct A,B,C — no wrong answers → partial credit
    r = score_mcq(["A,B"], ["A,B,C"])
    assert r["accuracy"] == 0.0
    assert abs(r["partial_credit_accuracy"] - 2 / 3) < 1e-9


def test_multi_partial_with_wrong_answer():
    # Predicted A,D out of correct A,B,C — D is wrong → zero credit
    r = score_mcq(["A,D"], ["A,B,C"])
    assert r["accuracy"] == 0.0
    assert r["partial_credit_accuracy"] == 0.0


def test_multi_single_correct_of_many():
    # Predicted just A out of correct A,B,C — partial credit 1/3
    r = score_mcq(["A"], ["A,B,C"])
    assert r["accuracy"] == 0.0
    assert abs(r["partial_credit_accuracy"] - 1 / 3) < 1e-9


def test_multi_wrong_only():
    # Predicted D, correct is A,B,C — zero credit
    r = score_mcq(["D"], ["A,B,C"])
    assert r["accuracy"] == 0.0
    assert r["partial_credit_accuracy"] == 0.0


# ── Edge cases ────────────────────────────────────────────────────────────────

def test_empty_list():
    r = score_mcq([], [])
    assert r["accuracy"] == 0.0
    assert r["total"] == 0


def test_per_question_length_matches_input():
    r = score_mcq(["A", "B", "C"], ["A", "C", "C"])
    assert len(r["per_question"]) == 3
    assert len(r["per_question_partial"]) == 3


def test_mixed_single_and_multi():
    # Q1: single correct, Q2: multi partial, Q3: single wrong
    r = score_mcq(["A", "A,B", "D"], ["A", "A,B,C", "C"])
    assert r["correct"] == 1
    assert r["total"] == 3
    assert abs(r["accuracy"] - 1 / 3) < 1e-9
    # partial: 1.0 + 2/3 + 0.0 = 5/3
    assert abs(r["partial_credit_accuracy"] - (1.0 + 2 / 3 + 0.0) / 3) < 1e-9
