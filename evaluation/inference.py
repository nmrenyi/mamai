"""
Unified inference backends for GGUF (llama-cpp-python) and HuggingFace models.

Generation parameters match the on-device config in RagPipeline.kt:37-39.
"""

import os
import sys
from abc import ABC, abstractmethod

from prompts import TEMPERATURE, TOP_P, TOP_K, N_CTX


def _detect_gpu_layers() -> int:
    """Return -1 (all layers on GPU) if CUDA is available, else 0 (CPU only)."""
    try:
        import llama_cpp
        # llama-cpp-python exposes CUDA support via shared lib; simplest check is platform
        # On Linux with CUDA build, GPU offload works. On macOS, CPU only.
        if sys.platform == "linux":
            return -1
    except ImportError:
        pass
    return 0


class ModelBackend(ABC):
    """Common interface for all inference backends."""

    @abstractmethod
    def generate(self, prompt: str, max_tokens: int = 512) -> str:
        ...


class GGUFBackend(ModelBackend):
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


class HFBackend(ModelBackend):
    """HuggingFace transformers backend for safetensors models."""

    def __init__(self, model_path: str, quantize_4bit: bool = False):
        import torch
        from transformers import AutoTokenizer, AutoModelForCausalLM

        print(f"Loading HF model: {model_path}")
        self.tokenizer = AutoTokenizer.from_pretrained(model_path)

        load_kwargs = {"device_map": "auto"}
        if quantize_4bit:
            from transformers import BitsAndBytesConfig

            load_kwargs["quantization_config"] = BitsAndBytesConfig(load_in_4bit=True)
            print("  (int4 quantized)")
        else:
            load_kwargs["dtype"] = torch.bfloat16
            print("  (bfloat16)")

        self.model = AutoModelForCausalLM.from_pretrained(model_path, **load_kwargs)
        self.device = self.model.device
        print("Model loaded.")

    def generate(self, prompt: str, max_tokens: int = 512) -> str:
        import torch

        inputs = self.tokenizer(prompt, return_tensors="pt").to(self.device)
        with torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=TEMPERATURE,
                top_p=TOP_P,
                top_k=TOP_K,
                do_sample=True,
            )
        text = self.tokenizer.decode(
            outputs[0][inputs["input_ids"].shape[1] :], skip_special_tokens=True
        )
        # Strip any trailing Gemma control tokens
        return text.replace("<end_of_turn>", "").strip()


# Model registry: name -> (backend_class, relative_path, kwargs)
MODEL_REGISTRY = {
    "gemma3n-e4b": ("gguf", "gemma-3n/gemma-3n-E4B-it-Q4_0.gguf", {}),
    "gemma3n-e2b": ("gguf", "gemma-3n/gemma-3n-E2B-it-Q4_0.gguf", {}),
    "medgemma-gguf": ("gguf", "medgemma-4b/medgemma-4b-it-Q4_0.gguf", {}),
    "medgemma-hf": ("hf", "medgemma", {}),
    "medgemma-hf-int4": ("hf", "medgemma", {"quantize_4bit": True}),
}


def load_model(name: str, model_dir: str, n_gpu_layers: int | None = None) -> ModelBackend:
    """Load a model by name from the registry."""
    if name not in MODEL_REGISTRY:
        raise ValueError(f"Unknown model: {name}. Available: {list(MODEL_REGISTRY.keys())}")

    backend_type, rel_path, kwargs = MODEL_REGISTRY[name]
    full_path = os.path.join(model_dir, rel_path)

    if backend_type == "gguf":
        layers = n_gpu_layers if n_gpu_layers is not None else _detect_gpu_layers()
        print(f"  GPU layers: {layers} ({'all on GPU' if layers == -1 else 'CPU only'})")
        return GGUFBackend(full_path, n_gpu_layers=layers)
    else:
        return HFBackend(full_path, **kwargs)
