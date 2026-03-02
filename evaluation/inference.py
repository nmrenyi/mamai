"""
Inference backend for GGUF models via llama-cpp-python.

Generation parameters match the on-device config in RagPipeline.kt:37-39.
"""

import os
import sys

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


MODEL_REGISTRY = {
    "gemma3n-e4b": "gemma-3n/gemma-3n-E4B-it-Q4_0.gguf",
    "gemma3n-e2b": "gemma-3n/gemma-3n-E2B-it-Q4_0.gguf",
    "medgemma-gguf": "medgemma-4b/medgemma-4b-it-Q4_0.gguf",
}


def load_model(name: str, model_dir: str, n_gpu_layers: int | None = None) -> GGUFBackend:
    """Load a model by name from the registry."""
    if name not in MODEL_REGISTRY:
        raise ValueError(f"Unknown model: {name}. Available: {list(MODEL_REGISTRY.keys())}")

    full_path = os.path.join(model_dir, MODEL_REGISTRY[name])
    layers = n_gpu_layers if n_gpu_layers is not None else _detect_gpu_layers()
    print(f"  GPU layers: {layers} ({'all on GPU' if layers == -1 else 'CPU only'})")
    return GGUFBackend(full_path, n_gpu_layers=layers)
