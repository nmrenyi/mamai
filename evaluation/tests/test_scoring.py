"""Tests for extract_letters() in scoring.py."""

import pytest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
from scoring import extract_letters


# ── Existing rules (regression) ──────────────────────────────────────────────

def test_single_letter():
    assert extract_letters("B") == {"B"}

def test_single_letter_with_explanation():
    assert extract_letters("A\n\nBecause the patient presents with...") == {"A"}

def test_letter_with_period():
    assert extract_letters("C. Levonorgestrel") == {"C"}

def test_letter_with_paren():
    assert extract_letters("(D)") == {"D"}

def test_multi_letter_comma():
    assert extract_letters("A, C, E") == {"A", "C", "E"}

def test_answer_is_pattern():
    assert extract_letters("The answer is B.") == {"B"}

def test_markdown_bold():
    assert extract_letters("**A**\n\nExplanation...") == {"A"}


# ── Rule 10: trailing quote/tag fallback (positive cases) ────────────────────

def test_trailing_double_quote():
    assert extract_letters('A"') == {"A"}

def test_trailing_single_quote():
    assert extract_letters("B'") == {"B"}

def test_trailing_start_of_turn_tag():
    assert extract_letters("B</start_of_turn>") == {"B"}

def test_trailing_body_tag():
    assert extract_letters("E</body>") == {"E"}

def test_trailing_html_tag():
    assert extract_letters("C</body></html>") == {"C"}

def test_trailing_open_tag():
    assert extract_letters("D<tag>") == {"D"}


# ── Rule 10: must NOT fire on non-letter-answer first lines (negative cases) ─

def test_no_match_explanation_line():
    assert extract_letters("Because the correct answer involves...") == set()

def test_no_match_markdown_heading():
    assert extract_letters("### Explanation\nThe answer is A.") == {"A"}

def test_no_match_long_first_line():
    # "The most appropriate next step is B." — rule 9 should catch this, not rule 10
    result = extract_letters("The most appropriate next step is B.")
    assert result == {"B"}

def test_no_match_letter_mid_word():
    # "Broad-spectrum..." — B followed by r, not a tag
    assert extract_letters("Broad-spectrum antibiotics") == set()
