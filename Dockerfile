# Multi-Container Production LLM Inference Service Dockerfile
FROM python:3.11-slim

# PyTorch wheel index. The default CPU-only index avoids pulling several GB of CUDA
# libraries that go unused without a GPU. For a GPU build, override it, e.g.:
#   docker compose build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu

# Prevent Python from writing .pyc files and enable unbuffered logging
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8000 \
    HOST=0.0.0.0 \
    HF_HOME=/home/appuser/.cache/huggingface

# Install runtime and healthcheck dependencies (curl)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Install Python dependencies first for caching layer efficiency.
# torch is installed from TORCH_INDEX_URL first; the pinned torch in requirements.txt is then already satisfied.
COPY requirements.txt /app/requirements.txt
RUN pip install --upgrade pip && \
    pip install "$(grep '^torch==' requirements.txt)" --index-url "$TORCH_INDEX_URL" && \
    pip install -r requirements.txt

# Copy application source code
COPY main.py ml_engine.py schemas.py /app/

# Create non-root user and the model cache directory it owns
# (a fresh named volume mounted at HF_HOME inherits this ownership)
RUN useradd -m -u 1000 appuser && \
    mkdir -p "$HF_HOME" && \
    chown -R appuser:appuser /app /home/appuser/.cache

USER appuser

# Expose API port
EXPOSE 8000

# Docker-native health check (long start period: the first boot downloads the model weights)
HEALTHCHECK --interval=15s --timeout=5s --start-period=300s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Launch production server with Uvicorn
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
