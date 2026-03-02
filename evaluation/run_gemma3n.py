"""
Run Gemma 3n E4B (Q4_0 GGUF) locally with the same config as the mobile app.
Usage:
  pip install llama-cpp-python
  python3 run_gemma3n.py
  python3 run_gemma3n.py --model models/gemma-3n/gemma-3n-E2B-it-Q4_0.gguf
"""

import argparse
from llama_cpp import Llama

from prompts import SYSTEM_PROMPT, TEMPERATURE, TOP_P, TOP_K, N_CTX

DEFAULT_MODEL = "models/gemma-3n/gemma-3n-E4B-it-Q4_0.gguf"

QUESTION = "What are the danger signs in a newborn in the first 24 hours?"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Path to GGUF model file")
    parser.add_argument("--n-ctx", type=int, default=N_CTX, help="Context window size")
    parser.add_argument("--max-tokens", type=int, default=512, help="Max tokens to generate")
    args = parser.parse_args()

    print(f"Loading model: {args.model}")
    llm = Llama(model_path=args.model, n_ctx=args.n_ctx, verbose=False)
    print("Model loaded.")

    prompt = (
        f"<start_of_turn>user\n"
        f"{SYSTEM_PROMPT}\n\n"
        f"Question: {QUESTION}<end_of_turn>\n"
        f"<start_of_turn>model\n"
    )

    print(f"\n{'='*60}")
    print(f"Question: {QUESTION}")
    print(f"{'='*60}\n")

    output = llm(
        prompt,
        max_tokens=args.max_tokens,
        temperature=TEMPERATURE,
        top_p=TOP_P,
        top_k=TOP_K,
        stop=["<end_of_turn>"],
    )
    print(output["choices"][0]["text"])


if __name__ == "__main__":
    main()
