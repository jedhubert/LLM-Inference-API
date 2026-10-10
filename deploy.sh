#!/usr/bin/env bash
# ==============================================================================
# Production LLM API Deployment & Health Verification Script
# Usage: ./deploy.sh
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

API_PORT="${PORT:-8000}"
HEALTH_URL="http://localhost:${API_PORT}/health"
# 100 x 3s = 5 minutes: the first deployment downloads ~2.2 GB of model weights.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-100}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-3}"

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}🚀 Starting Production Deployment: LLM Inference API  ${NC}"
echo -e "${BLUE}======================================================${NC}"

# Step 1: Pull latest code if in a Git repository
echo -e "\n${YELLOW}▶ Step 1: Checking for repository updates...${NC}"
if command -v git &> /dev/null && [ -d ".git" ]; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    echo "Pulling latest changes from branch: ${CURRENT_BRANCH}..."
    git pull origin "${CURRENT_BRANCH}" || {
        echo -e "${YELLOW}⚠️ Git pull failed or no upstream configured; continuing with local files.${NC}"
    }
else
    echo "No Git repository detected or git CLI not found. Deploying local directory state."
fi

# Step 2: Build Docker Compose images
echo -e "\n${YELLOW}▶ Step 2: Building container images...${NC}"
docker compose build --pull

# Step 3: Start services in detached mode
echo -e "\n${YELLOW}▶ Step 3: Orchestrating multi-container startup...${NC}"
docker compose up -d --remove-orphans

# Step 4: Health check probe loop
echo -e "\n${YELLOW}▶ Step 4: Polling /health endpoint for readiness (${HEALTH_URL})...${NC}"
attempt=1
healthy=false

while [ $attempt -le $MAX_ATTEMPTS ]; do
    echo -n "Probe attempt ${attempt}/${MAX_ATTEMPTS}: "
    
    # Run curl probe against /health
    HTTP_CODE=$(curl -s -o /tmp/health_response.json -w "%{http_code}" "${HEALTH_URL}" 2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" -eq 200 ]; then
        echo -e "${GREEN}HTTP 200 OK${NC}"
        healthy=true
        break
    else
        echo -e "${YELLOW}Status ${HTTP_CODE} (waiting for model loading & services)...${NC}"
        sleep $SLEEP_INTERVAL
        attempt=$((attempt + 1))
    fi
done

echo -e "\n${BLUE}======================================================${NC}"
if [ "$healthy" = true ]; then
    echo -e "${GREEN}✅ DEPLOYMENT SUCCESSFUL! All services healthy.${NC}"
    echo -e "${GREEN}Response Payload:${NC}"
    cat /tmp/health_response.json 2>/dev/null && echo ""
    echo -e "\n${GREEN}Active Containers:${NC}"
    docker compose ps
    exit 0
else
    echo -e "${RED}❌ DEPLOYMENT FAILED: Service did not become healthy within $((MAX_ATTEMPTS * SLEEP_INTERVAL)) seconds.${NC}"
    echo -e "\n${RED}Last Probe Response (if any):${NC}"
    cat /tmp/health_response.json 2>/dev/null && echo ""
    echo -e "\n${RED}API Container Logs (Diagnosis):${NC}"
    docker compose logs --tail=40 api
    exit 1
fi
