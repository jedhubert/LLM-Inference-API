FROM python:3.11-slim

ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8000 \
    HOST=0.0.0.0 \
    HF_HOME=/home/appuser/.cache/huggingface

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --upgrade pip && \
    pip install "$(grep '^torch==' requirements.txt)" --index-url "$TORCH_INDEX_URL" && \
    pip install -r requirements.txt

COPY main.py ml_engine.py schemas.py /app/

RUN useradd -m -u 1000 appuser && \
    mkdir -p "$HF_HOME" && \
    chown -R appuser:appuser /app /home/appuser/.cache

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=5s --start-period=300s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
