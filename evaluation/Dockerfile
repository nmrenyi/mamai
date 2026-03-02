FROM nvidia/cuda:12.4.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies
RUN apt-get update && apt-get install -y \
    python3.10 python3.10-venv python3-pip \
    git cmake build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/python3.10 /usr/bin/python3 && \
    ln -sf /usr/bin/python3 /usr/bin/python

WORKDIR /app

# Python dependencies (llama-cpp-python compiled with CUDA support)
COPY requirements.txt .
RUN CMAKE_ARGS="-DGGML_CUDA=on" FORCE_CMAKE=1 \
    pip install --no-cache-dir -r requirements.txt

# Evaluation code and data (not models — those mount from PVC)
COPY prompts.py inference.py scoring.py run_eval.py ./
COPY data/ ./data/

ENTRYPOINT ["python3", "run_eval.py"]
