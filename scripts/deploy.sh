#!/usr/bin/env bash
# deploy.sh — SmartApps DevOps Deployment Script
# Author    : Nelson Ngumo
# Company   : Smart Applications International
#
# WHAT THIS SCRIPT DOES
# ---------------------
# 1. Builds a Docker image from docker/Dockerfile
# 2. Tags it using semantic versioning (e.g. 1.2.0-qa, 1.2.0-prod)
# 3. Validates the image locally (spins up container, curls /health)
# 4. Pushes to the correct registry based on --env parameter
# 5. Enforces a QA promotion gate before any prod push
# 6. Tracks every deployment in .version_history.log
# 7. Supports instant rollback to last stable version
#
# USAGE
# -----
#   ./scripts/deploy.sh --env qa   --version 1.2.0        # Build & push to QA
#   ./scripts/deploy.sh --env prod --version 1.2.0        # Promote QA → Prod
#   ./scripts/deploy.sh --env prod --rollback             # Rollback prod
#   ./scripts/deploy.sh --env qa   --version 1.2.0 --dry-run  # Preview only
#
# PREREQUISITES (local)
# ---------------------
#   - Docker running
#   - docker compose up -d registry-qa registry-prod  (from docker/ folder)
#   - .env.qa and .env.prod copied from .env.*.example

set -euo pipefail

# Always run from the project root regardless of where the script is invoked from
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Colours for readable terminal output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${RESET}    $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET}   $*"; }
log_step()    { echo -e "\n${BOLD}${BLUE}━━━ $* ${RESET}"; }

# Defaults
IMAGE_NAME="smartapps-service"
DOCKERFILE="docker/Dockerfile"
VERSION_LOG="./scripts/.version_history.log"
ENVIRONMENT=""
VERSION=""
DRY_RUN=false
ROLLBACK=false
LOCAL_TEST_PORT=18080
HEALTH_CHECK_RETRIES=5
HEALTH_CHECK_INTERVAL=3

# Usage
usage() {
  cat <<EOF

${BOLD}USAGE${RESET}
  ./scripts/deploy.sh [OPTIONS]

${BOLD}OPTIONS${RESET}
  -e, --env        Environment: qa | prod                     (required)
  -v, --version    Semantic version: MAJOR.MINOR.PATCH        (required unless --rollback)
  -n, --name       Image/service name       (default: smartapps-service)
  -f, --file       Path to Dockerfile       (default: docker/Dockerfile)
      --dry-run    Print actions without executing
      --rollback   Rollback to last stable image for this env
  -h, --help       Show this help

${BOLD}EXAMPLES${RESET}
  # Local development — build and push to local QA registry
  ./scripts/deploy.sh --env qa --version 1.2.0

  # Promote tested QA image to Production
  ./scripts/deploy.sh --env prod --version 1.2.0

  # Preview what a prod deploy would do
  ./scripts/deploy.sh --env prod --version 1.2.0 --dry-run

  # Rollback production to last stable
  ./scripts/deploy.sh --env prod --rollback

${BOLD}PREREQUISITES${RESET}
  Local:  docker compose -f docker/docker-compose.yml up -d registry-qa registry-prod
  CI/CD:  Set REGISTRY_URL, REGISTRY_USER, REGISTRY_PASS as env vars (Jenkins injects these)

EOF
  exit 0
}

# Argument parsing
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)       ENVIRONMENT="$2"; shift 2 ;;
    -v|--version)   VERSION="$2";     shift 2 ;;
    -n|--name)      IMAGE_NAME="$2";  shift 2 ;;
    -f|--file)      DOCKERFILE="$2";  shift 2 ;;
       --dry-run)   DRY_RUN=true;     shift   ;;
       --rollback)  ROLLBACK=true;    shift   ;;
    -h|--help)      usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

# Input validation
validate_inputs() {
  log_step "Validating inputs"

  [[ -z "$ENVIRONMENT" ]] && { log_error "--env is required."; usage; }

  case "$ENVIRONMENT" in
    qa|prod) ;;
    *) log_error "--env must be 'qa' or 'prod'. Got: '${ENVIRONMENT}'"; exit 1 ;;
  esac

  if ! $ROLLBACK; then
    [[ -z "$VERSION" ]] && { log_error "--version is required."; usage; }

    # Enforce strict semantic versioning format
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      log_error "Version '${VERSION}' does not follow MAJOR.MINOR.PATCH format."
      log_error "Examples: 1.0.0  |  2.3.1  |  0.12.4"
      exit 1
    fi
  fi

  [[ ! -f "$DOCKERFILE" ]] && { log_error "Dockerfile not found at: ${DOCKERFILE}"; exit 1; }

  log_success "Inputs valid — env=${ENVIRONMENT} version=${VERSION:-rollback} dry_run=${DRY_RUN}"
}

# Load environment config from .env file based on environment (qa/prod).NEVER hard-codes credentials.
load_env_config() {
  log_step "Loading environment configuration"

  local env_file=".env.${ENVIRONMENT}"

  if [[ -f "$env_file" ]]; then
    log_info "Sourcing config from: ${env_file}"
    # Export vars from file while filtering blank lines and comments
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  else
    log_info "No ${env_file} file found — expecting env vars to be already exported"
    log_info "(In Jenkins this is normal — values injected by withCredentials)"
  fi

  # Validate required variables are now available
  : "${REGISTRY_URL:?REGISTRY_URL is not set. Copy .env.${ENVIRONMENT}.example to .env.${ENVIRONMENT} and fill it in.}"

  log_success "Config loaded for environment: ${ENVIRONMENT}"
}

# Resolve full registry address and image tags based on ENV
resolve_registry() {
  log_step "Resolving registry"

  # Determine registry port based on environment
  case "$ENVIRONMENT" in
    qa)   REGISTRY_PORT="${REGISTRY_PORT:-5001}" ;;
    prod) REGISTRY_PORT="${REGISTRY_PORT:-5000}" ;;
  esac

  FULL_REGISTRY="${REGISTRY_URL}:${REGISTRY_PORT}"

  # Semantic version tag
  IMAGE_TAG="${VERSION}-${ENVIRONMENT}"
  FULL_IMAGE="${FULL_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
  LATEST_TAG="${FULL_REGISTRY}/${IMAGE_NAME}:latest-${ENVIRONMENT}"

  log_info "Registry   : ${FULL_REGISTRY}"
  log_info "Image tag  : ${IMAGE_TAG}"
  log_info "Full image : ${FULL_IMAGE}"
}

# Docker registry login
registry_login() {
  # Skip login if no credentials provided (local insecure registry)
  if [[ -z "${REGISTRY_USER:-}" ]] || [[ -z "${REGISTRY_PASS:-}" ]]; then
    log_warn "No registry credentials set — assuming local insecure registry (ok for local dev)"
    return 0
  fi

  log_step "Authenticating to registry"

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would run: docker login ${FULL_REGISTRY}"
    return 0
  fi

  echo "${REGISTRY_PASS}" | docker login "${FULL_REGISTRY}" \
    --username "${REGISTRY_USER}" \
    --password-stdin

  log_success "Registry login successful."
}

# Build Docker image
build_image() {
  log_step "Building Docker image"

  local git_commit
  git_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  local build_time
  build_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  log_info "Dockerfile : ${DOCKERFILE}"
  log_info "Context    : . (project root)"
  log_info "Git commit : ${git_commit}"

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would run: docker build -t ${FULL_IMAGE} ..."
    return 0
  fi

  docker build \
    --file "${DOCKERFILE}" \
    --build-arg APP_VERSION="${VERSION}" \
    --build-arg BUILD_ENV="${ENVIRONMENT}" \
    --label "org.opencontainers.image.version=${VERSION}" \
    --label "org.opencontainers.image.revision=${git_commit}" \
    --label "org.opencontainers.image.created=${build_time}" \
    --label "build.environment=${ENVIRONMENT}" \
    --label "build.pipeline=${BUILD_URL:-local}" \
    --tag "${FULL_IMAGE}" \
    --tag "${LATEST_TAG}" \
    .

  log_success "Image built: ${FULL_IMAGE}"
}

# Local validation (MANDATORY before any push).Starts the image locally, waits for it to be healthy, curls /health.If this fails — the script ABORTS. Nothing is pushed to any registry.
validate_locally() {
  log_step "Local validation (health check)"

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would spin up ${FULL_IMAGE} and curl /health"
    return 0
  fi

  log_info "Starting container for local validation ..."

  # Start container detached on a high port to avoid conflicts
  local container_id
  container_id=$(docker run -d --rm \
    --name "smartapps-validate-$$" \
    -p "${LOCAL_TEST_PORT}:8080" \
    -e APP_ENV="${ENVIRONMENT}" \
    -e APP_VERSION="${VERSION}" \
    "${FULL_IMAGE}")

  log_info "Container ID: ${container_id:0:12}"
  log_info "Waiting for service to start ..."

  local attempt=0
  local http_code="000"

  while [[ $attempt -lt $HEALTH_CHECK_RETRIES ]]; do
    sleep "${HEALTH_CHECK_INTERVAL}"
    attempt=$((attempt + 1))

    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      "http://localhost:${LOCAL_TEST_PORT}/health" 2>/dev/null || echo "000")

    log_info "Health check attempt ${attempt}/${HEALTH_CHECK_RETRIES} — HTTP ${http_code}"

    if [[ "$http_code" == "200" ]]; then
      break
    fi
  done

  # Print container logs regardless — useful for debugging
  log_info "Container logs:"
  docker logs "${container_id}" 2>&1 | sed 's/^/  > /'

  # Stop the validation container
  docker stop "${container_id}" > /dev/null 2>&1 || true

  if [[ "$http_code" != "200" ]]; then
    log_error "Health check FAILED after ${HEALTH_CHECK_RETRIES} attempts (last HTTP: ${http_code})"
    log_error "Image ${FULL_IMAGE} will NOT be pushed."
    log_error "Fix the application or Dockerfile and try again."
    exit 1
  fi

  log_success "Health check PASSED — HTTP 200 from /health"
}

# QA promotion gate (prod only)
# Verifies that the QA-tagged version of this image actually exists in the QA registry before allowing it to be pushed to Production.This prevents "build-and-push-straight-to-prod" accidents.
check_qa_gate() {
  log_step "QA Promotion Gate"

  local qa_port="${QA_REGISTRY_PORT:-5001}"
  local qa_registry="${REGISTRY_URL}:${qa_port}"
  local qa_image="${qa_registry}/${IMAGE_NAME}:${VERSION}-qa"

  log_info "Checking for QA image: ${qa_image}"

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would verify ${qa_image} exists"
    return 0
  fi

  # Query registry API directly (works with plain HTTP local registries)
  local qa_tags
  qa_tags=$(curl -sf "http://${qa_registry}/v2/${IMAGE_NAME}/tags/list" 2>/dev/null || echo '{}')
  if ! echo "${qa_tags}" | grep -q "${VERSION}-qa"; then
    log_error "QA image does not exist: ${qa_image}"
    log_error "You must build and validate QA before promoting to Production."
    log_error "Run: ./scripts/deploy.sh --env qa --version ${VERSION}"
    exit 1
  fi

  log_success "QA gate PASSED — image exists: ${qa_image}"
}

# Push image to registry
push_image() {
  log_step "Pushing image to registry"

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would push: ${FULL_IMAGE}"
    log_info "[DRY-RUN] Would push: ${LATEST_TAG}"
    return 0
  fi

  log_info "Pushing ${FULL_IMAGE} ..."
  docker push "${FULL_IMAGE}"

  log_info "Pushing ${LATEST_TAG} ..."
  docker push "${LATEST_TAG}"

  log_success "Push complete."
  record_version "PUSHED"
}

# Version history tracking.Every deployment is written to .version_history.log
record_version() {
  local status="$1"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  mkdir -p "$(dirname "${VERSION_LOG}")"
  echo "${timestamp} | ENV=${ENVIRONMENT} | IMAGE=${FULL_IMAGE} | STATUS=${status}" \
    >> "${VERSION_LOG}"

  log_info "Version recorded: ${status}"
}

mark_stable() {
  record_version "STABLE"
  log_success "Version ${FULL_IMAGE} marked as STABLE"
}

get_last_stable() {
  # Returns the last STABLE image for the given environment
  grep "ENV=${ENVIRONMENT}" "${VERSION_LOG}" 2>/dev/null \
    | grep "STATUS=STABLE" \
    | tail -2 | head -1 \
    | awk -F'IMAGE=' '{print $2}' \
    | awk '{print $1}'
}

# Show version history
show_history() {
  log_step "Version History — ${ENVIRONMENT}"
  if [[ -f "${VERSION_LOG}" ]]; then
    grep "ENV=${ENVIRONMENT}" "${VERSION_LOG}" | tail -20 | while IFS= read -r line; do
      echo "  ${line}"
    done
  else
    log_warn "No version history found at ${VERSION_LOG}"
  fi
}

# Rollback
# Two strategies:
#   1. If running on Kubernetes (kubectl available + cluster set): kubectl rollout undo
#   2. Fallback: get last STABLE tag from version log, re-deploy it
rollback() {
  log_step "ROLLBACK — ${ENVIRONMENT}"

  if [[ ! -f "${VERSION_LOG}" ]]; then
    log_error "No version history found. Cannot rollback."
    log_error "Deploy at least two versions before attempting rollback."
    exit 1
  fi

  show_history

  local last_stable
  last_stable=$(get_last_stable)

  if [[ -z "${last_stable}" ]]; then
    log_error "No STABLE version found for env=${ENVIRONMENT} in ${VERSION_LOG}"
    log_error "A version is marked STABLE after a successful push + health check."
    exit 1
  fi

  log_info "Rolling back to: ${last_stable}"

  if $DRY_RUN; then
    log_info "[DRY-RUN] Would pull and re-deploy: ${last_stable}"
    return 0
  fi

  # Pull the stable image from registry
  log_info "Pulling stable image ..."
  docker pull "${last_stable}"

  # Re-tag it as rollback-<timestamp> for audit trail
  local rollback_tag="${FULL_REGISTRY}/${IMAGE_NAME}:rollback-$(date +%s)"
  docker tag "${last_stable}" "${rollback_tag}"

  log_info "Pushing rollback tag: ${rollback_tag} ..."
  docker push "${rollback_tag}"

  record_version "ROLLBACK"

  log_success "Rollback complete."
  echo ""
  log_info "The stable image is now available as:"
  echo -e "  ${BOLD}${last_stable}${RESET}"
  echo -e "  ${BOLD}${rollback_tag}${RESET}"
  echo ""
  log_info "Next step — update your orchestration platform:"
  log_info "  Kubernetes : kubectl set image deployment/smartapps-service smartapps-service=${last_stable} -n ${ENVIRONMENT}"
  log_info "  Compose    : docker compose -f docker/docker-compose.yml up -d (update image: in compose file first)"
}

# Print deployment summary
print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║           DEPLOYMENT COMPLETE                            ║${RESET}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════╣${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Environment : ${BOLD}${ENVIRONMENT^^}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Version     : ${BOLD}${VERSION}${RESET}"
  echo -e "${BOLD}${GREEN}║${RESET}  Image       : ${FULL_IMAGE}"
  echo -e "${BOLD}${GREEN}║${RESET}  Registry    : ${FULL_REGISTRY}"
  echo -e "${BOLD}${GREEN}║${RESET}  Dry Run     : ${DRY_RUN}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

# MAIN FLOW
main() {
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${BLUE}║    SmartApps DevOps — Deployment Script                  ║${RESET}"
  echo -e "${BOLD}${BLUE}║    $(date -u +'%Y-%m-%d %H:%M:%S UTC')                          ║${RESET}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${RESET}"

  validate_inputs
  load_env_config
  resolve_registry

  # ROLLBACK PATH
  if $ROLLBACK; then
    registry_login
    rollback
    exit 0
  fi

  # NORMAL DEPLOY PATH
  registry_login
  build_image
  validate_locally

  case "$ENVIRONMENT" in
    qa)
      push_image
      mark_stable
      ;;
    prod)
      check_qa_gate    # MUST have QA image in registry first
      push_image
      mark_stable
      ;;
  esac

  print_summary
}

main "$@"
