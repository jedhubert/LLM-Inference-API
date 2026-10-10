import os
import json
import time
import hashlib
import secrets
from typing import Optional, Any
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Response, status

try:
    import redis
except ImportError:
    redis = None

from ml_engine import llm_engine
from schemas import GenerationRequest, GenerationResponse, HealthCheckResponse

# Configuration from Environment Variables
REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_PASSWORD = os.getenv("REDIS_PASSWORD") or None
REDIS_DB = int(os.getenv("REDIS_DB", "0"))
CACHE_TTL_SECONDS = int(os.getenv("CACHE_TTL_SECONDS", "3600"))
# Minimum delay between reconnection attempts while Redis is unreachable, so that a
# Redis outage does not add a connect timeout to every single request.
REDIS_RETRY_SECONDS = float(os.getenv("REDIS_RETRY_SECONDS", "15"))
# When set, /generate and DELETE /cache require a matching X-API-Key header.
API_KEY = os.getenv("API_KEY") or None

redis_client: Optional[Any] = None
_last_redis_attempt: float = 0.0

def get_redis_client() -> Optional[Any]:
    """Initializes and returns the Redis client, retrying at most every REDIS_RETRY_SECONDS."""
    global redis_client, _last_redis_attempt
    if redis is None:
        return None
    if redis_client is None:
        now = time.monotonic()
        if _last_redis_attempt and now - _last_redis_attempt < REDIS_RETRY_SECONDS:
            return None
        _last_redis_attempt = now
        try:
            client = redis.Redis(
                host=REDIS_HOST,
                port=REDIS_PORT,
                password=REDIS_PASSWORD,
                db=REDIS_DB,
                socket_timeout=1.0,
                socket_connect_timeout=1.0,
                decode_responses=True
            )
            if client.ping():
                redis_client = client
                print(f"[SUCCESS] Connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
        except Exception as e:
            print(f"[WARNING] Redis unavailable at {REDIS_HOST}:{REDIS_PORT}: {e}")
            redis_client = None
    return redis_client

def reset_redis_client():
    """Drops a broken connection so the next call reconnects (subject to the retry delay)."""
    global redis_client, _last_redis_attempt
    redis_client = None
    _last_redis_attempt = time.monotonic()

def compute_cache_key(model_id: str, prompt: str, max_tokens: int, temperature: float) -> str:
    """Generates a unique SHA-256 fingerprint for caching inference results."""
    raw_payload = f"{model_id}||{prompt.strip()}||{max_tokens}||{round(temperature, 2)}"
    digest = hashlib.sha256(raw_payload.encode("utf-8")).hexdigest()
    return f"llm_cache:{digest}"

def require_api_key(x_api_key: Optional[str] = Header(default=None)):
    """Rejects the request unless it carries the configured API key (no-op when API_KEY is unset)."""
    if API_KEY is None:
        return
    if x_api_key is None or not secrets.compare_digest(x_api_key, API_KEY):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or missing API key")

@asynccontextmanager
async def lifespan(app: FastAPI):
    print("[INFO] Initializing Production LLM Inference Service...")
    if API_KEY is None:
        print("[WARNING] API_KEY is not set; /generate and DELETE /cache are open to anyone who can reach this port.")
    # Trigger non-blocking async background model load
    llm_engine.load_model_async()
    yield
    print("[INFO] Shutting down LLM Inference Service...")
    global redis_client
    if redis_client:
        try:
            redis_client.close()
        except Exception:
            pass

app = FastAPI(
    title="Production LLM Inference API",
    description="LLM inference API with Docker Compose orchestration and Redis caching",
    version="1.1.0",
    lifespan=lifespan
)

@app.get("/", summary="Root status check")
def read_root():
    return {
        "service": "Production LLM Inference API",
        "status": "online",
        "model": llm_engine.model_id,
        "model_loaded": llm_engine.is_ready(),
        "is_loading": llm_engine.is_loading
    }

@app.get("/health", response_model=HealthCheckResponse, summary="Service health and readiness probe")
def health_check(response: Response):
    """
    Comprehensive health check for container orchestration and host monitoring.
    Verifies LLM pipeline memory readiness and Redis container connectivity.
    Error specifics are written to the server log rather than returned to callers.
    """
    model_ready = llm_engine.is_ready()
    redis_conn = False

    try:
        client = get_redis_client()
        if client and client.ping():
            redis_conn = True
    except Exception as e:
        print(f"[WARNING] Redis health ping failed: {e}")
        reset_redis_client()

    # Determine overall status
    if model_ready and redis_conn:
        overall_status = "healthy"
    elif model_ready and not redis_conn:
        overall_status = "degraded" # LLM can serve inference, caching bypassed
    elif llm_engine.is_loading:
        overall_status = "initializing"
    else:
        overall_status = "unhealthy"

    # Set HTTP 503 if not fully ready or unhealthy
    if overall_status in ("unhealthy", "initializing"):
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE

    return HealthCheckResponse(
        status=overall_status,
        model_loaded=model_ready,
        redis_connected=redis_conn,
        model_id=llm_engine.model_id,
        timestamp=time.time(),
        details={
            "is_loading": llm_engine.is_loading,
            "load_failed": llm_engine.load_error is not None,
            "cache_ttl_seconds": CACHE_TTL_SECONDS
        }
    )

@app.post(
    "/generate",
    response_model=GenerationResponse,
    summary="Execute prompt inference with caching",
    dependencies=[Depends(require_api_key)]
)
def generate_text(request: GenerationRequest):
    """
    Generates text using the loaded LLM.

    Only deterministic requests (temperature 0) are cached: caching a sampled response
    would replay one random completion to every later caller.
    """
    if not llm_engine.is_ready():
        if llm_engine.is_loading:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Model is currently initializing into memory. Please retry in a few moments."
            )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Model unavailable. Check the server logs for details."
        )

    start_time = time.perf_counter()
    cacheable = request.temperature == 0
    cache_key = compute_cache_key(llm_engine.model_id, request.prompt, request.max_tokens, request.temperature)
    client = get_redis_client() if cacheable else None

    # 1. Check Redis Cache
    if client:
        try:
            cached_data = client.get(cache_key)
            if cached_data:
                parsed = json.loads(cached_data)
                latency = (time.perf_counter() - start_time) * 1000.0
                return GenerationResponse(
                    result=parsed["result"],
                    token_usage=parsed["token_usage"],
                    cached=True,
                    latency_ms=round(latency, 2)
                )
        except Exception as cache_err:
            print(f"[WARNING] Cache read error: {cache_err}")
            reset_redis_client()
            client = None

    # 2. Cache Miss: Run Model Inference
    try:
        result, token_usage = llm_engine.generate(
            prompt=request.prompt,
            max_new_tokens=request.max_tokens,
            temperature=request.temperature
        )
    except Exception as e:
        print(f"[ERROR] Inference failed: {e}")
        raise HTTPException(status_code=500, detail="Inference error. Check the server logs for details.")

    # 3. Store result in Redis cache
    if client:
        try:
            payload = json.dumps({"result": result, "token_usage": token_usage})
            client.setex(cache_key, CACHE_TTL_SECONDS, payload)
        except Exception as cache_err:
            print(f"[WARNING] Cache write error: {cache_err}")
            reset_redis_client()

    latency = (time.perf_counter() - start_time) * 1000.0
    return GenerationResponse(
        result=result,
        token_usage=token_usage,
        cached=False,
        latency_ms=round(latency, 2)
    )

@app.delete("/cache", summary="Flush inference cache", dependencies=[Depends(require_api_key)])
def flush_cache():
    """Clears all cached inference results in Redis."""
    client = get_redis_client()
    if not client:
        raise HTTPException(status_code=503, detail="Redis service unavailable")
    try:
        # SCAN in batches instead of KEYS, which blocks Redis while it walks the whole keyspace.
        deleted_count = 0
        batch = []
        for key in client.scan_iter(match="llm_cache:*", count=500):
            batch.append(key)
            if len(batch) >= 500:
                deleted_count += client.delete(*batch)
                batch = []
        if batch:
            deleted_count += client.delete(*batch)
        return {"status": "success", "cleared_entries": deleted_count}
    except Exception as e:
        print(f"[ERROR] Cache flush failed: {e}")
        raise HTTPException(status_code=500, detail="Cache flush failed. Check the server logs for details.")
