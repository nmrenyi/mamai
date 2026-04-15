"""Smoke tests: importing the eval modules must succeed cleanly.

Both scoring.py and prompts.py load config files at module import time.
If any config file is malformed, missing a key, or has a wrong type,
the import fails and the entire eval harness is broken. This test catches
that before a run is attempted.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))


def test_scoring_importable():
    import scoring  # noqa: F401


def test_prompts_importable():
    import prompts  # noqa: F401


def test_scoring_exports_expected_symbols():
    import scoring
    assert callable(scoring.extract_letters)
    assert callable(scoring.extract_letter)
    assert callable(scoring.score_mcq)
    assert isinstance(scoring.JUDGE_TEMPERATURE, float)


def test_prompts_exports_expected_symbols():
    import prompts
    assert isinstance(prompts.APP_SYSTEM_PROMPT, str) and prompts.APP_SYSTEM_PROMPT
    assert isinstance(prompts.MCQ_SYSTEM_PROMPT, str) and prompts.MCQ_SYSTEM_PROMPT
    assert isinstance(prompts.PROTOCOL_VERSION, str) and prompts.PROTOCOL_VERSION
    assert isinstance(prompts.PROMPT_VERSION, str) and prompts.PROMPT_VERSION
    assert isinstance(prompts.SPEC_SHA256, str) and len(prompts.SPEC_SHA256) == 64
    assert isinstance(prompts.TEMPERATURE, float)
    assert isinstance(prompts.RETRIEVAL_TOP_K, int)


def test_prompts_system_prompt_nonempty():
    import prompts
    assert len(prompts.APP_SYSTEM_PROMPT) > 50, "APP_SYSTEM_PROMPT looks suspiciously short"
    assert len(prompts.MCQ_SYSTEM_PROMPT) > 50, "MCQ_SYSTEM_PROMPT looks suspiciously short"


def test_prompts_build_functions_return_strings():
    import prompts
    mcq = prompts.build_mcq_prompt("What is the treatment?", "A. Drug1 | B. Drug2")
    assert isinstance(mcq, str) and "<start_of_turn>" in mcq

    open_q = prompts.build_open_prompt("What is the treatment for malaria?")
    assert isinstance(open_q, str) and "<start_of_turn>" in open_q


def test_prompts_rag_builders_inject_context():
    import prompts
    ctx = "Malaria is treated with artemisinin."
    mcq = prompts.build_rag_mcq_prompt("What is the treatment?", "A. Drug1 | B. Drug2", ctx)
    assert ctx in mcq

    open_q = prompts.build_rag_open_prompt("What is the treatment for malaria?", ctx)
    assert ctx in open_q
