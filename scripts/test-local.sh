#!/usr/bin/env bash
# test-local.sh — Run the COMPLETE pipeline locally
# It simulates:
#   1. Starting local QA and Prod Docker registries
#   2. Building the Docker image
#   3. Running health check validation
#   4. Pushing to QA local registry
#   5. Promoting to Prod local registry (with QA gate check)
#   6. Simulating a rollback
#
# USAGE
# -----
#   chmod +x scripts/test-local.sh
#   ./scripts/test-local.sh

set -euo pipefail

# Always run from the project root
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; exit 1; }
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
step() { echo -e "\n${BOLD}${BLUE}━━━ STEP $* ${RESET}"; }

TEST_VERSION="1.0.0"
DEPLOY_SCRIPT="./scripts/deploy.sh"

echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   SmartApps — Full Local Pipeline Test               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# Step 1: Start local registries
step "1 — Start local Docker registries"

info "Starting QA registry (port 5001) and Prod registry (port 5000) ..."
docker compose -f docker/docker-compose.yml up -d registry-qa registry-prod

# Wait for registries to be ready
info "Waiting for registries to be healthy ..."
for i in {1..10}; do
  if curl -sf http://localhost:5001/v2/ > /dev/null 2>&1 && \
     curl -sf http://localhost:5000/v2/ > /dev/null 2>&1; then
    break
  fi
  sleep 2
  if [[ $i -eq 10 ]]; then
    fail "Registries did not start in time. Check: docker compose -f docker/docker-compose.yml logs"
  fi
done

pass "Local registries started"
info "  QA registry   → http://localhost:5001"
info "  Prod registry → http://localhost:5000"

# Step 2: Set up local env config
step "2 — Configure local environment files"

if [[ ! -f ".env.qa" ]]; then
  info "Creating .env.qa from example ..."
  cp .env.qa.example .env.qa
fi

if [[ ! -f ".env.prod" ]]; then
  info "Creating .env.prod from example ..."
  cp .env.prod.example .env.prod
fi

pass "Environment config ready (.env.qa, .env.prod)"

# Step 3: Build and push to QA
step "3 — Build and push to QA registry"

info "Running: deploy.sh --env qa --version ${TEST_VERSION}"
chmod +x "$DEPLOY_SCRIPT"
"$DEPLOY_SCRIPT" --env qa --version "$TEST_VERSION"

pass "QA image built and pushed: localhost:5001/smartapps-service:${TEST_VERSION}-qa"

# Step 4: Verify QA image in registry
step "4 — Verify QA image in registry"

info "Querying QA registry for tags ..."
QA_TAGS=$(curl -s http://localhost:5001/v2/smartapps-service/tags/list 2>/dev/null || echo '{}')
info "QA registry tags: ${QA_TAGS}"

if echo "$QA_TAGS" | grep -q "${TEST_VERSION}-qa"; then
  pass "Image tag ${TEST_VERSION}-qa confirmed in QA registry"
else
  fail "Tag ${TEST_VERSION}-qa not found in QA registry. Push may have failed."
fi

# Step 5: Run container directly and test health endpoint
step "5 — Direct container health check test"

info "Starting QA container directly on port 8085 ..."
docker run -d --rm \
  --name smartapps-direct-test \
  -p 8085:8080 \
  -e APP_ENV=qa \
  -e APP_VERSION="${TEST_VERSION}" \
  "localhost:5001/smartapps-service:${TEST_VERSION}-qa" > /dev/null

sleep 4

HEALTH=$(curl -sf http://localhost:8085/health 2>/dev/null || echo "FAILED")
info "Health response: ${HEALTH}"

docker stop smartapps-direct-test > /dev/null 2>&1 || true

if echo "$HEALTH" | grep -q '"status":"healthy"'; then
  pass "Health endpoint returned healthy status"
else
  fail "Health endpoint did not return expected response"
fi

# Step 6: Promote QA → Prod
step "6 — Promote QA → Production (QA gate enforced)"

info "Running: deploy.sh --env prod --version ${TEST_VERSION}"
info "This will enforce the QA gate — verifying ${TEST_VERSION}-qa exists in QA registry"
"$DEPLOY_SCRIPT" --env prod --version "$TEST_VERSION"

pass "Production image pushed: localhost:5000/smartapps-service:${TEST_VERSION}-prod"

# Step 7: Verify prod image
step "7 — Verify Production image in registry"

PROD_TAGS=$(curl -s http://localhost:5000/v2/smartapps-service/tags/list 2>/dev/null || echo '{}')
info "Prod registry tags: ${PROD_TAGS}"

if echo "$PROD_TAGS" | grep -q "${TEST_VERSION}-prod"; then
  pass "Image tag ${TEST_VERSION}-prod confirmed in Prod registry"
else
  fail "Tag ${TEST_VERSION}-prod not found in Prod registry."
fi

# Step 8: Simulate rollback
step "8 — Simulate rollback"

info "Running: deploy.sh --env prod --rollback"
"$DEPLOY_SCRIPT" --env prod --rollback

pass "Rollback simulation complete"

# Step 9: Show version history
step "9 — Version history log"

if [[ -f "./scripts/.version_history.log" ]]; then
  info "Contents of .version_history.log:"
  sed 's/^/  /' < ./scripts/.version_history.log
else
  info "No version history log found (expected if --dry-run was used)"
fi

# Summary
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   ALL TESTS PASSED                                   ║${RESET}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${GREEN}║${RESET}  QA image   : localhost:5001/smartapps-service:${TEST_VERSION}-qa"
echo -e "${BOLD}${GREEN}║${RESET}  Prod image : localhost:5000/smartapps-service:${TEST_VERSION}-prod"
echo -e "${BOLD}${GREEN}║${RESET}  Rollback   : verified"
echo -e "${BOLD}${GREEN}║${RESET}  History    : scripts/.version_history.log"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"

info "To clean up local registries: docker compose -f docker/docker-compose.yml down -v"
