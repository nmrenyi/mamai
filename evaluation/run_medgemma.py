"""
Run MedGemma 4B locally with the same config as the mobile app.
Usage: python3 run_medgemma.py
"""

import torch
from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig

MODEL_PATH = "models/medgemma"

SYSTEM_PROMPT = (
    "You are a medical assistant supporting nurses and midwives in Zanzibar. "
    "You help with neonatal care, maternal health, obstetrics, and related clinical topics.\n"
    "Only answer questions related to healthcare, medicine, and clinical practice. "
    "For unrelated topics, politely decline and redirect to medical questions.\n\n"
    "LANGUAGE & TONE: Use simple, short sentences. Avoid idioms and complex words. "
    "Answer in the language that the user is speaking. Be supportive, professional, and calm.\n\n"
    "FORMAT: Use markdown. Use bullet points for lists. Use **bold** for important terms. "
    "Use numbered steps for procedures. Keep responses concise — under 200 words unless a procedure genuinely requires more detail.\n\n"
    "EMERGENCIES — if any of these are present, immediately tell the user to call a doctor or emergency service and state why:\n"
    "- Heavy bleeding (postpartum haemorrhage, antepartum haemorrhage)\n"
    "- Convulsions or loss of consciousness (eclampsia)\n"
    "- Cord prolapse or abnormal fetal presentation\n"
    "- Shoulder dystocia\n"
    "- Severe difficulty breathing (mother or newborn)\n"
    "- Fever in a newborn or signs of neonatal sepsis\n"
    "- Signs of maternal sepsis (fever, rapid pulse, confusion in the mother)\n"
    "- Severe abdominal pain\n\n"
    "MEDICATIONS: Do not recommend specific drug doses unless the retrieved context explicitly states them. "
    "If asked about dosing, advise the user to consult a senior clinician or the local formulary.\n\n"
    "UNCERTAINTY: If you are not sure, admit it clearly. Do not guess. Prioritize patient safety above all else."
)

QUESTION = "What are the danger signs in a newborn in the first 24 hours?"


def main():
    print("Loading tokenizer...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_PATH)

    print("Loading model (int4 quantized, ~4 GB)...")
    quantization_config = BitsAndBytesConfig(load_in_4bit=True)
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_PATH,
        quantization_config=quantization_config,
        device_map="auto",
    )
    print("Model loaded.")

    # Build prompt using Gemma IT chat template (same as mobile app)
    prompt = (
        f"<start_of_turn>user\n"
        f"{SYSTEM_PROMPT}\n\n"
        f"Question: {QUESTION}<end_of_turn>\n"
        f"<start_of_turn>model\n"
    )

    print(f"\n{'='*60}")
    print(f"Question: {QUESTION}")
    print(f"{'='*60}\n")

    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)

    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=512,
            temperature=1.0,
            top_p=0.95,
            top_k=64,
            do_sample=True,
        )

    # Decode only the generated part (skip the prompt tokens)
    response = tokenizer.decode(outputs[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)
    print(response)


if __name__ == "__main__":
    main()
