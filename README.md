# Production LLM Inference API (FastAPI + Docker Compose + Redis)

A high-performance, containerized LLM Inference Service architecture built with FastAPI, Hugging Face Transformers, Docker Compose, and Redis response caching.

---

## 🏗️ Architecture Overview

```mermaid
graph TD
    Client["Client / Load Balancer"] -->|HTTP REST| API["FastAPI Container (llm_inference_api)"]
    API -->|Prompt Fingerprint SHA256| Redis["Redis Cache Container (llm_redis_cache)"]
    Redis -.->|Cache Hit (<5ms)| API
    API -->|Cache Miss| LLM["TinyLlama 1.1B Engine (PyTorch)"]
    LLM -->|Generate & Store| Redis
    HostCron["Host Cron / Monitoring"] -->|/health Probe| API
```

### Key Components:
1. **FastAPI Engine (`main.py`)**: REST server with `/generate`, `/health`, and `/cache` endpoints.
2. **Redis Cache Container (`redis:7.2-alpine`)**: In-memory prompt-response cache with TTL eviction (`allkeys-lru`) to eliminate redundant GPU/CPU inference cycles.
3. **Model Weight Persistence (`hf_cache` volume)**: Docker volume caching Hugging Face model checkpoints to avoid re-downloading across deployments.
4. **Automated Deployment (`deploy.sh` / `deploy.ps1`)**: Single-command CI/CD script that rebuilds images, restarts containers, and polls the health endpoint with exponential backoff.
5. **Host-Level Monitoring (`healthcheck_cron.sh` / `healthcheck_cron.ps1`)**: Background probe logging anomalies, degraded state, or downtime to log files.
6. **Root Cause Analysis Playbook (`TROUBLESHOOTING.md`)**: Comprehensive guide on simulating failures (wrong env vars, port conflicts) and diagnosing with `docker inspect` and `docker logs`.

---

## 🚀 Quick Start

### 1. Start Services via Docker Compose
```bash
docker compose up -d --build
```

### 2. Verify Health
```bash
curl -i http://localhost:8000/health
```

### 3. Generate Inference
```bash
curl -X POST http://localhost:8000/generate \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{
    "prompt": "Explain quantum computing in one sentence.",
    "max_tokens": 64,
    "temperature": 0
  }'
```

The `X-API-Key` header is required only when `API_KEY` is set (copy `.env.example` to `.env` and fill it in). Without it, `/generate` and `DELETE /cache` are open to anyone who can reach port 8000.

### 4. Test Redis Caching
Repeat the same request above. Notice that `cached: true` is returned and `latency_ms` drops from several seconds to < 5ms.

Only deterministic requests (`"temperature": 0`) are cached. Requests with a higher temperature always run the model, so that each caller gets a fresh sample instead of a replayed one. The cache key includes the model ID, so changing `MODEL_ID` never serves the old model's answers.

### 5. Run the Tests
The tests stub the model and Redis, so they run in seconds without Docker:
```bash
python -m unittest discover -s tests -v
```

---

## ⚙️ Capacity Notes

- Inference runs one request at a time (one Uvicorn worker, a lock around the model); concurrent requests wait their turn. For real throughput, put a dedicated server such as vLLM or TGI behind this API.
- The image installs CPU-only PyTorch. For a GPU build, pass `--build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128` and give the `api` service a GPU reservation in `docker-compose.yml`.
- The model needs about 4.4 GB of free RAM in float32 on CPU.
- Redis is not published on the host. Use `docker compose exec redis redis-cli` to inspect it.

---

## 🛠️ Automated Deployment

Run the automated deployment script (with healthcheck loop):
- **Linux/macOS**:
  ```bash
  chmod +x deploy.sh
  ./deploy.sh
  ```
- **Windows PowerShell**:
  ```powershell
  .\deploy.ps1
  ```

---

## 🔍 Root-Cause Diagnosis & Troubleshooting

For detailed failure injection exercises (e.g. broken environment variables, wrong ports) and diagnosis workflows using `docker inspect` and `docker compose logs`, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
