# Root-Cause Diagnosis & Troubleshooting Playbook

This document provides a production-grade diagnostic framework and step-by-step walkthrough for deliberately injecting failures, triaging root causes using Docker and Linux CLI tools (`curl`, `docker logs`, `docker inspect`, `docker exec`), and restoring healthy service operations.

---

## 1. DevOps Diagnostic Toolkit

When troubleshooting containerized inference workloads, follow this 5-stage triage workflow:

| Stage | Goal | Key Command |
| :--- | :--- | :--- |
| **1. Probe** | Check service availability & response code | `curl -i http://localhost:8000/health` |
| **2. Orchestration State** | Inspect container running status & health status | `docker compose ps` |
| **3. Runtime Logs** | View application stack traces & runtime warnings | `docker compose logs --tail=100 -f api` |
| **4. Deep Inspection** | Inspect container environment, IPs, network, mounts | `docker inspect llm_inference_api` |
| **5. Network Reachability** | Test inter-container DNS and socket connectivity | `docker compose exec api curl/nc/ping` |

---

## 2. Failure Scenarios: Deliberate Break, Diagnosis & Fix

---

### Scenario A: Broken Environment Variable (`REDIS_HOST` Misconfiguration)

#### Step 1: Inject the Failure
Modify `docker-compose.yml` or your `.env` to point to a non-existent Redis hostname:
```yaml
# In docker-compose.yml under 'api' service environment:
environment:
  - REDIS_HOST=redis_wrong_hostname
  - REDIS_PORT=6379
```
Apply the broken configuration:
```bash
docker compose up -d
```

#### Step 2: Observe Symptoms via Probe
Run a healthcheck probe from the host:
```bash
curl -s http://localhost:8000/health
```
**Output Received:**
```json
{
  "status": "degraded",
  "model_loaded": true,
  "redis_connected": false,
  "model_id": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
  "timestamp": 1718800000.0,
  "details": {
    "is_loading": false,
    "load_failed": false,
    "cache_ttl_seconds": 3600
  }
}
```
The probe deliberately doesn't return hostnames or error text to callers. The specific error is in the container logs (next step).

#### Step 3: Deep Inspection via Docker CLI
1. **Check Container Logs:**
   ```bash
   docker compose logs --tail=30 api
   ```
   *Log snippet:*
   ```text
   [WARNING] Redis unavailable at redis_wrong_hostname:6379: Error -2 connecting to redis_wrong_hostname:6379. Name or service not known.
   ```

2. **Inspect Container Environment Variables with `docker inspect`:**
   ```bash
   docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' llm_inference_api
   ```
   *Output reveals:*
   ```text
   REDIS_HOST=redis_wrong_hostname
   REDIS_PORT=6379
   PORT=8000
   ```

3. **Verify DNS & Inter-Container Network Resolution:**
   ```bash
   docker compose exec api getent hosts redis_wrong_hostname
   # Result: Returns empty / host not found (Exit code 2)
   ```

#### Step 4: Fix and Verify Recovery
1. Revert `REDIS_HOST=redis` in `docker-compose.yml`.
2. Recreate the container:
   ```bash
   docker compose up -d
   ```
3. Verify resolution:
   ```bash
   curl -s http://localhost:8000/health
   # Returns: {"status": "healthy", "model_loaded": true, "redis_connected": true, ...}
   ```

---

### Scenario B: Port Collision / Port Binding Mismatch

#### Step 1: Inject the Failure
Change the internal container listening port while keeping external mapping unchanged:
```yaml
# In docker-compose.yml:
environment:
  - PORT=9000  # Application starts listening on 9000
ports:
  - "8000:8000" # Docker forwards host:8000 to container:8000 (which is now empty!)
```
Apply:
```bash
docker compose up -d
```

#### Step 2: Observe Symptoms via Probe
```bash
curl -i http://localhost:8000/health
```
**Output Received:**
```text
curl: (52) Empty reply from server
# OR
curl: (7) Failed to connect to localhost port 8000: Connection refused
```

#### Step 3: Diagnosis via `docker compose ps` & `docker inspect`
1. **Check Health & Container State:**
   ```bash
   docker compose ps
   ```
   *Output shows container becoming `unhealthy`:*
   ```text
   NAME                IMAGE              COMMAND                  SERVICE   STATUS                     PORTS
   llm_inference_api   llm-api-api        "uvicorn main:app --…"   api       Up 45 seconds (unhealthy)   0.0.0.0:8000->8000/tcp
   ```

2. **Inspect Docker Healthcheck Logs:**
   ```bash
   docker inspect --format='{{json .State.Health}}' llm_inference_api | jq .
   ```
   *Output shows healthcheck failing with exit code 7 (curl connection refused to port 8000).*

3. **Inspect Process Listening Ports:**
   ```bash
   docker compose logs --tail=20 api
   ```
   *Log snippet:*
   ```text
   INFO:     Uvicorn running on http://0.0.0.0:9000 (Press CTRL+C to quit)
   ```
   *Root Cause Identified: Application is bound to port 9000, but Docker is forwarding traffic to port 8000.*

#### Step 4: Fix and Verify Recovery
1. Match both ports to `8000` in `docker-compose.yml` (`PORT=8000`, `8000:8000`).
2. Run `./deploy.sh` to redeploy and trigger automated health probes.

---

### Scenario C: Model Repository Failure (Invalid Model ID / HuggingFace Network Block)

#### Step 1: Inject the Failure
Set an invalid HuggingFace model repository:
```yaml
environment:
  - MODEL_ID=invalid_org/this_model_does_not_exist_404
```
Apply:
```bash
docker compose up -d
```

#### Step 2: Observe Symptoms
```bash
curl -i http://localhost:8000/health
```
Probe returns `HTTP 503 Service Unavailable` or container exits immediately (`CrashLoopBackOff`).

#### Step 3: Diagnosis via `docker compose logs`
```bash
docker compose logs api
```
*Stack trace:*
```text
huggingface_hub.utils._errors.RepositoryNotFoundError: 404 Client Error.
Repository Not Found for url: https://huggingface.co/invalid_org/this_model_does_not_exist_404
```

#### Step 4: Fix and Verify Recovery
1. Set `MODEL_ID=TinyLlama/TinyLlama-1.1B-Chat-v1.0` in `docker-compose.yml`.
2. Redeploy with `docker compose up -d`.

---

## 3. Host Cron Job Monitoring Setup

### Linux / macOS (Crontab)

1. Make the script executable:
   ```bash
   chmod +x ./healthcheck_cron.sh
   ```

2. Add a crontab entry to probe the endpoint every 2 minutes:
   ```bash
   crontab -e
   ```
   Insert the following line:
   ```cron
   */2 * * * * /absolute/path/to/LLM\ API/healthcheck_cron.sh >> /var/log/llm_cron_runner.log 2>&1
   ```

3. View failure logs in real time:
   ```bash
   tail -f ./logs/llm_health_failures.log
   ```

### Windows (PowerShell Scheduled Task)

1. Open PowerShell as Administrator.
2. Register the scheduled task to execute every 5 minutes:
   ```powershell
   $Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -File "C:\path\to\LLM API\healthcheck_cron.ps1"'
   $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
   Register-ScheduledTask -Action $Action -Trigger $Trigger -TaskName "LLM_Inference_HealthCheck" -Description "Monitors FastAPI LLM Health"
   ```

3. Verify task registration:
   ```powershell
   Get-ScheduledTask -TaskName "LLM_Inference_HealthCheck"
   ```
