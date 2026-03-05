"""
Prompt templates for medical QA evaluation.

Two prompt styles:
- MCQ_SYSTEM_PROMPT: focused exam-answering prompt for multiple-choice questions
- OPEN_SYSTEM_PROMPT: focused clinical QA prompt for open-ended questions
- APP_SYSTEM_PROMPT: the on-device RAG app prompt (from RagPipeline.kt), kept for reference
"""

import hashlib

# --- Task-specific evaluation prompts ---

MCQ_SYSTEM_PROMPT = (
    "You are a medical expert taking a clinical exam. "
    "Answer each multiple-choice question by selecting the single best answer. "
    "Reply with ONLY the letter of the correct option (e.g., 'B'). "
    "Do not add explanations or disclaimers."
)

OPEN_SYSTEM_PROMPT = (
    "You are a knowledgeable medical professional. "
    "Answer the following clinical question thoroughly and accurately. "
    "Be specific, use medical terminology where appropriate, and provide actionable guidance. "
    "Structure your answer clearly with bullet points or numbered steps when relevant."
)

# --- On-device app prompt (RagPipeline.kt:293-317), kept for reference ---

APP_SYSTEM_PROMPT = (
    "You are a medical assistant supporting nurses and midwives in Zanzibar. "
    "You help with neonatal care, maternal health, obstetrics, and related clinical topics.\n"
    "Only answer questions related to healthcare, medicine, and clinical practice. "
    "For unrelated topics, politely decline and redirect to medical questions.\n"
    "\n"
    "CONVERSATION: You may have access to previous messages in this conversation "
    "\u2014 use them to maintain context and avoid repeating information already covered.\n"
    "\n"
    "LANGUAGE & TONE: Use simple, short sentences. Avoid idioms and complex words. "
    "Answer in the language that the user is speaking. Be supportive, professional, and calm.\n"
    "\n"
    "FORMAT: Use markdown. Use bullet points for lists. Use **bold** for important terms. "
    "Use numbered steps for procedures. Keep responses concise \u2014 under 200 words "
    "unless a procedure genuinely requires more detail.\n"
    "\n"
    "USING CONTEXT: If retrieved context is provided, use it to answer. "
    "If the context is not relevant to the question, say so and answer from "
    "established medical knowledge instead.\n"
    "\n"
    "EMERGENCIES \u2014 if any of these are present, immediately tell the user to call "
    "a doctor or emergency service and state why:\n"
    "- Heavy bleeding (postpartum haemorrhage, antepartum haemorrhage)\n"
    "- Convulsions or loss of consciousness (eclampsia)\n"
    "- Cord prolapse or abnormal fetal presentation\n"
    "- Shoulder dystocia\n"
    "- Severe difficulty breathing (mother or newborn)\n"
    "- Fever in a newborn or signs of neonatal sepsis\n"
    "- Signs of maternal sepsis (fever, rapid pulse, confusion in the mother)\n"
    "- Severe abdominal pain\n"
    "\n"
    "MEDICATIONS: Do not recommend specific drug doses unless the retrieved context "
    "explicitly states them. If asked about dosing, advise the user to consult a "
    "senior clinician or the local formulary.\n"
    "\n"
    "UNCERTAINTY: If you are not sure, admit it clearly "
    '(e.g., \u201cI\u2019m not sure. Please ask a doctor or senior nurse.\u201d). '
    "Do not guess. Prioritize patient safety above all else."
)

# On-device generation parameters (RagPipeline.kt:37-39)
TEMPERATURE = 1.0
TOP_P = 0.95
TOP_K = 64
N_CTX = 4096  # the whole conversation is not going to exceed 4096, less context window could save memory

def _prompt_hash(*prompts: str) -> str:
    """Short hash of prompt content — changes automatically when prompts are edited."""
    h = hashlib.sha256("".join(prompts).encode()).hexdigest()[:8]
    return f"v2-{h}"

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
            f"RELEVANT CONTEXT FROM MEDICAL GUIDELINES:\n{context}\n\n"
            f"Question: {question}\nOptions:\n{options}"
        ),
    }


def build_rag_open_messages(question: str, context: str) -> dict:
    """Open-ended prompt with RAG context."""
    return {
        "system": OPEN_SYSTEM_PROMPT,
        "user": (
            f"RELEVANT CONTEXT FROM MEDICAL GUIDELINES:\n{context}\n\n"
            f"Question: {question}"
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
