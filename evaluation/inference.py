"""
Inference backend for GGUF models via llama-cpp-python.

Generation parameters match the on-device config in RagPipeline.kt:37-39.
"""

import os

from prompts import TEMPERATURE, TOP_P, TOP_K, N_CTX


def _detect_gpu_layers() -> int:
    """Return -1 (all layers on GPU) if CUDA is available, else 0 (CPU only)."""
    try:
        import ctypes
        ctypes.CDLL("libcuda.so")
        return -1
    except OSError:
        pass
    return 0


class GGUFBackend:
    """llama-cpp-python backend for GGUF models."""

    def __init__(self, model_path: str, n_gpu_layers: int = -1):
        from llama_cpp import Llama

        print(f"Loading GGUF model: {model_path}")
        self.llm = Llama(
            model_path=model_path,
            n_ctx=N_CTX,
            n_gpu_layers=n_gpu_layers,
            verbose=False,
        )
        print("Model loaded.")

    def generate(self, prompt: str, max_tokens: int = 512) -> str:
        output = self.llm(
            prompt,
            max_tokens=max_tokens,
            temperature=TEMPERATURE,
            top_p=TOP_P,
            top_k=TOP_K,
            stop=["<end_of_turn>"],
        )
        return output["choices"][0]["text"].strip()


class OpenAIBackend:
    """OpenAI API backend for chat models (GPT-5, GPT-4o, etc.)."""

    is_api = True

    def __init__(self, model: str):
        from openai import OpenAI

        self.client = OpenAI()  # uses OPENAI_API_KEY env var
        self.model = model
        print(f"Using OpenAI API model: {model}")

    def generate(self, messages: dict, max_tokens: int = 512) -> str:
        result = self.client.chat.completions.create(
            model=self.model,
            messages=[
                {"role": "system", "content": messages["system"]},
                {"role": "user", "content": messages["user"]},
            ],
            max_completion_tokens=max_tokens,
            temperature=TEMPERATURE,
        )
        return result.choices[0].message.content.strip()


MODEL_REGISTRY = {
    # Local GGUF models
    "gemma3n-e4b": ("gguf", "gemma-3n/gemma-3n-E4B-it-Q4_0.gguf"),
    "gemma3n-e2b": ("gguf", "gemma-3n/gemma-3n-E2B-it-Q4_0.gguf"),
    "medgemma-gguf": ("gguf", "medgemma-4b/medgemma-4b-it-Q4_0.gguf"),
    # OpenAI API models
    "gpt-5": ("openai", "gpt-5"),
    "gpt-4o": ("openai", "gpt-4o"),
}


def load_model(name: str, model_dir: str = "", n_gpu_layers: int | None = None):
    """Load a model by name from the registry."""
    if name not in MODEL_REGISTRY:
        raise ValueError(f"Unknown model: {name}. Available: {list(MODEL_REGISTRY.keys())}")

    backend_type, model_path = MODEL_REGISTRY[name]

    if backend_type == "openai":
        return OpenAIBackend(model_path)

    # GGUF backend
    full_path = os.path.join(model_dir, model_path)
    layers = n_gpu_layers if n_gpu_layers is not None else _detect_gpu_layers()
    print(f"  GPU layers: {layers} ({'all on GPU' if layers == -1 else 'CPU only'})")
    return GGUFBackend(full_path, n_gpu_layers=layers)
