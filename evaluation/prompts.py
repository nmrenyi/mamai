"""
Prompt templates for medical QA evaluation.

Protocol: app_parity_v1
  The open-ended system prompt is the same text as the deployed Android app
  (config/prompts/system_en.txt), so open-ended eval scores reflect actual
  app behavior. MCQ uses a separate adapter prompt from
  config/prompts/mcq_system.txt because the app prompt is not designed to
  output a single letter — see GitHub issue #39.

Single source of truth for all config: config/ at repo root.
"""

import hashlib
import json
from pathlib import Path

_CONFIG_DIR  = Path(__file__).parents[1] / "config"
_PROMPTS_DIR = _CONFIG_DIR / "prompts"
_runtime  = json.loads((_CONFIG_DIR / "runtime_config.json").read_text())
_evalcfg  = json.loads((_CONFIG_DIR / "eval_config.json").read_text())

# --- App system prompt (single source of truth: config/prompts/system_en.txt) ---

APP_SYSTEM_PROMPT: str = (_PROMPTS_DIR / "system_en.txt").read_text(encoding="utf-8").rstrip("\n")
APP_SYSTEM_PROMPT_SW: str = (_PROMPTS_DIR / "system_sw.txt").read_text(encoding="utf-8").rstrip("\n")

# --- MCQ adapter prompt ---
# NOT the app prompt. Required because the app prompt produces clinical prose,
# which breaks single-letter extraction. MCQ scores are a knowledge proxy,
# not a deployment-fidelity measure. See GitHub issue #39.
MCQ_SYSTEM_PROMPT: str = (_PROMPTS_DIR / "mcq_system.txt").read_text(encoding="utf-8").rstrip("\n")

# Open-ended eval uses the real app prompt — scores now reflect deployed behavior.
OPEN_SYSTEM_PROMPT = APP_SYSTEM_PROMPT

# --- Runtime parameters (single source of truth: config/runtime_config.json) ---
TEMPERATURE: float = _runtime["generation"]["temperature"]
TOP_P: float = _runtime["generation"]["top_p"]
TOP_K: int = _runtime["generation"]["top_k"]
RETRIEVAL_TOP_K: int = _runtime["retrieval"]["top_k"]
RETRIEVAL_THRESHOLD: float = _runtime["retrieval"]["similarity_threshold"]
CONTEXT_LABEL: str = _runtime["context_injection"]["context_label_en"]
QUESTION_LABEL: str = _runtime["context_injection"]["question_label_en"]

# eval-only: LiteRT-LM manages context window internally, no app equivalent
N_CTX: int = _evalcfg["n_ctx"]

# --- Protocol versioning ---

PROTOCOL_VERSION = "app_parity_v1"

def _spec_sha256() -> str:
    """SHA-256 of the canonical English system prompt file (config/prompts/system_en.txt)."""
    return hashlib.sha256((_PROMPTS_DIR / "system_en.txt").read_bytes()).hexdigest()

SPEC_SHA256: str = _spec_sha256()


def _prompt_hash(*prompts: str) -> str:
    """Short hash of prompt content — changes automatically when prompts are edited."""
    h = hashlib.sha256("".join(prompts).encode()).hexdigest()[:8]
    return f"v3-{h}"

PROMPT_VERSION = _prompt_hash(MCQ_SYSTEM_PROMPT, OPEN_SYSTEM_PROMPT)


def _format_gemma_it(system: str, user: str) -> str:
    """Wrap system + user content in Gemma IT chat template."""
    return (
        f"<start_of_turn>user\n{system}\n\n{user}<end_of_turn>\n"
        f"<start_of_turn>model\n"
    )


def build_mcq_messages(question: str, options: str) -> dict:
    """Return model-agnostic {system, user} messages for MCQ."""
    return {
        "system": MCQ_SYSTEM_PROMPT,
        "user": f"Question: {question}\nOptions:\n{options}",
    }


def build_open_messages(question: str) -> dict:
    """Return model-agnostic {system, user} messages for open-ended."""
    return {
        "system": OPEN_SYSTEM_PROMPT,
        "user": question,
    }


def build_mcq_prompt(question: str, options: str) -> str:
    """Build a Gemma IT prompt for a multiple-choice question."""
    msgs = build_mcq_messages(question, options)
    return _format_gemma_it(msgs["system"], msgs["user"])


def build_open_prompt(question: str) -> str:
    """Build a Gemma IT prompt for an open-ended clinical question."""
    msgs = build_open_messages(question)
    return _format_gemma_it(msgs["system"], msgs["user"])


# --- RAG-augmented prompt builders ---

def build_rag_mcq_messages(question: str, options: str, context: str) -> dict:
    """MCQ prompt with RAG context. Same system prompt, context injected in user message."""
    return {
        "system": MCQ_SYSTEM_PROMPT,
        "user": (
            f"{CONTEXT_LABEL}\n{context}\n\n"
            f"{QUESTION_LABEL} {question}\nOptions:\n{options}"
        ),
    }


def build_rag_open_messages(question: str, context: str) -> dict:
    """Open-ended prompt with RAG context. Uses app system prompt (app_parity_v1)."""
    return {
        "system": OPEN_SYSTEM_PROMPT,
        "user": (
            f"{CONTEXT_LABEL}\n{context}\n\n"
            f"{QUESTION_LABEL} {question}"
        ),
    }


def build_rag_mcq_prompt(question: str, options: str, context: str) -> str:
    """Gemma IT prompt for MCQ with RAG context."""
    msgs = build_rag_mcq_messages(question, options, context)
    return _format_gemma_it(msgs["system"], msgs["user"])


def build_rag_open_prompt(question: str, context: str) -> str:
    """Gemma IT prompt for open-ended with RAG context."""
    msgs = build_rag_open_messages(question, context)
    return _format_gemma_it(msgs["system"], msgs["user"])
