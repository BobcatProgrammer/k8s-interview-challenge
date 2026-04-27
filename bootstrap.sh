#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="challenge"
GITEA_CONTAINER="kind-interview-gitea"
GITEA_PORT="3000"
GITEA_USER="challenge"
GITEA_PASS="challenge123"
GITEA_REPO="repo"
FLUX_INTERVAL="30s"
CONTAINER_ENGINE=""  # set by detect_container_engine()

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Detect container engine — Docker or Podman
# ---------------------------------------------------------------------------
# Preference order: docker first (more widely tested with kind), then podman.
# Podman Desktop (macOS / Windows / Linux) is fully supported.
# Plain rootless Podman on Linux is not officially supported by kind.
detect_container_engine() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    CONTAINER_ENGINE="podman"
    # Tell kind to use Podman as the node container runtime
    export KIND_EXPERIMENTAL_PROVIDER=podman
  else
    die "No running container engine found.
  Docker Desktop → https://docs.docker.com/get-docker/
  Podman Desktop → https://podman-desktop.io"
  fi
  info "Container engine: ${CONTAINER_ENGINE}"
}

# ---------------------------------------------------------------------------
# 2. Preflight checks
# ---------------------------------------------------------------------------
check_prereqs() {
  log "Checking prerequisites..."
  local missing=()
  for cmd in kind kubectl flux git; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ${#missing[@]} -ne 0 ]; then
    die "Missing required tools: ${missing[*]}

  kind    → https://kind.sigs.k8s.io/docs/user/quick-start/#installation
  kubectl → https://kubernetes.io/docs/tasks/tools/
  flux    → https://fluxcd.io/flux/installation/#install-the-flux-cli
  git     → https://git-scm.com/downloads"
  fi
  log "All prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# 3. Git setup
# ---------------------------------------------------------------------------
setup_git() {
  log "Setting up local git repository..."

  if [ ! -d "${SCRIPT_DIR}/.git" ]; then
    git -C "${SCRIPT_DIR}" init -b main
    git -C "${SCRIPT_DIR}" -c user.email="challenge@local" \
                            -c user.name="Challenge" \
                            add .
    git -C "${SCRIPT_DIR}" -c user.email="challenge@local" \
                            -c user.name="Challenge" \
                            commit -m "chore: initial challenge setup"
  else
    local current_branch
    current_branch=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$current_branch" != "main" ]; then
      git -C "${SCRIPT_DIR}" checkout -b main 2>/dev/null || \
        git -C "${SCRIPT_DIR}" checkout main
    fi
  fi
}

# ---------------------------------------------------------------------------
# 4. Shared container network
# ---------------------------------------------------------------------------
# Gitea and the kind cluster nodes are placed on the same 'kind' network.
# This means Flux inside the cluster can reach Gitea directly via its
# container IP — no host-IP detection, no firewall rules, works on all
# platforms with both Docker and Podman.
#
# kind will use a pre-existing network named 'kind' if one already exists,
# so creating it here before the cluster is safe and idempotent.
setup_network() {
  log "Ensuring 'kind' container network exists..."
  $CONTAINER_ENGINE network create kind 2>/dev/null \
    && info "Created 'kind' network." \
    || info "'kind' network already exists — reusing."
}

# ---------------------------------------------------------------------------
# 5. Gitea git server
# ---------------------------------------------------------------------------
start_gitea() {
  log "Starting Gitea git server (localhost:${GITEA_PORT})..."

  $CONTAINER_ENGINE rm -f "${GITEA_CONTAINER}" >/dev/null 2>&1 || true

  # GITEA_ADMIN_* env vars are supported in the official Gitea 1.21 Docker
  # image — the entrypoint creates the admin user automatically on first start,
  # avoiding the need to exec into the container at all.
  $CONTAINER_ENGINE run -d \
    --name "${GITEA_CONTAINER}" \
    --network kind \
    -p "${GITEA_PORT}:3000" \
    -e GITEA__security__INSTALL_LOCK=true \
    -e GITEA__database__DB_TYPE=sqlite3 \
    -e GITEA__server__HTTP_PORT=3000 \
    -e GITEA__server__DOMAIN=localhost \
    -e GITEA__service__DISABLE_REGISTRATION=true \
    -e GITEA__log__LEVEL=Error \
    -e GITEA_ADMIN_USERNAME="${GITEA_USER}" \
    -e GITEA_ADMIN_PASSWORD="${GITEA_PASS}" \
    -e GITEA_ADMIN_EMAIL="${GITEA_USER}@local" \
    gitea/gitea:1.21 >/dev/null

  # Stage 1: wait for the health endpoint (process is up)
  info "Waiting for Gitea to be ready (up to 90s)..."
  local elapsed=0
  until curl -sf "http://localhost:${GITEA_PORT}/api/healthz" >/dev/null 2>&1; do
    sleep 3
    elapsed=$((elapsed + 3))
    [ $elapsed -lt 90 ] || die "Gitea did not start within 90 seconds."
  done

  # Stage 2: wait for the v1 API endpoint (DB migrations complete)
  info "Waiting for Gitea API to be fully initialized..."
  elapsed=0
  until curl -sf "http://localhost:${GITEA_PORT}/api/v1/version" >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    [ $elapsed -lt 30 ] || die "Gitea API v1 did not become ready."
  done

  # Stage 3: wait for admin user to be available via API.
  # GITEA_ADMIN_* creates the user during startup; this loop confirms it.
  # If the env-var approach is not supported by the image, fall back to exec.
  info "Waiting for Gitea admin user to be ready..."
  elapsed=0
  until curl -sf -u "${GITEA_USER}:${GITEA_PASS}" \
      "http://localhost:${GITEA_PORT}/api/v1/user" >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ $elapsed -ge 20 ]; then
      # GITEA_ADMIN_* not supported — fall back to exec (no --must-change-password flag)
      info "Falling back to exec-based admin user creation..."
      local exec_out
      exec_out=$($CONTAINER_ENGINE exec -u git "${GITEA_CONTAINER}" \
        gitea admin user create \
          --username "${GITEA_USER}" \
          --password "${GITEA_PASS}" \
          --email "${GITEA_USER}@local" \
          --admin 2>&1) \
        || curl -sf -u "${GITEA_USER}:${GITEA_PASS}" \
             "http://localhost:${GITEA_PORT}/api/v1/user" >/dev/null 2>&1 \
        || die "Failed to create Gitea admin user.

  Error output: ${exec_out}

  To debug, run:
    ${CONTAINER_ENGINE} exec ${GITEA_CONTAINER} gitea admin user create \\
      --username ${GITEA_USER} --password ${GITEA_PASS} \\
      --email ${GITEA_USER}@local --admin"
      break
    fi
  done

  # Create public repo — check HTTP status, retry on failure
  info "Creating Gitea repository..."
  local attempts=10
  while true; do
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://localhost:${GITEA_PORT}/api/v1/user/repos" \
      -u "${GITEA_USER}:${GITEA_PASS}" \
      -H 'Content-Type: application/json' \
      -d "{\"name\":\"${GITEA_REPO}\",\"auto_init\":false,\"private\":false}")
    case "$http_code" in
      201) break ;;            # created successfully
      409) break ;;            # already exists — idempotent re-run
      *)
        attempts=$((attempts - 1))
        [ $attempts -gt 0 ] || die "Failed to create Gitea repository (HTTP ${http_code})."
        sleep 3
        ;;
    esac
  done

  # Point 'origin' at Gitea (credentials embedded for push)
  if git -C "${SCRIPT_DIR}" remote get-url origin >/dev/null 2>&1; then
    git -C "${SCRIPT_DIR}" remote set-url origin \
      "http://${GITEA_USER}:${GITEA_PASS}@localhost:${GITEA_PORT}/${GITEA_USER}/${GITEA_REPO}.git"
  else
    git -C "${SCRIPT_DIR}" remote add origin \
      "http://${GITEA_USER}:${GITEA_PASS}@localhost:${GITEA_PORT}/${GITEA_USER}/${GITEA_REPO}.git"
  fi

  git -C "${SCRIPT_DIR}" push origin HEAD:main --force >/dev/null
  log "Gitea ready — http://localhost:${GITEA_PORT}/${GITEA_USER}/${GITEA_REPO}"
}

# ---------------------------------------------------------------------------
# 6. Gitea container IP on the kind network
# ---------------------------------------------------------------------------
# Flux runs inside kind nodes. Those nodes are also on the 'kind' network,
# so they can reach Gitea at its container IP without any host routing.
get_gitea_ip() {
  local ip
  # Works for both Docker and Podman (same Go-template inspect format)
  ip=$($CONTAINER_ENGINE inspect "${GITEA_CONTAINER}" \
         --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
         2>/dev/null | tr -d '[:space:]' | head -c 20)
  [ -n "$ip" ] || die "Could not determine Gitea's IP on the 'kind' network.
  Try: ${CONTAINER_ENGINE} inspect ${GITEA_CONTAINER}"
  echo "$ip"
}

# ---------------------------------------------------------------------------
# 7. kind cluster
# ---------------------------------------------------------------------------
create_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
  else
    log "Creating kind cluster '${CLUSTER_NAME}'..."
    kind create cluster \
      --name "${CLUSTER_NAME}" \
      --config "${SCRIPT_DIR}/kind-config.yaml"
  fi
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
}

# ---------------------------------------------------------------------------
# 8. Flux
# ---------------------------------------------------------------------------
install_flux() {
  local gitea_ip="$1"
  # Flux talks to Gitea over the shared kind network — no host routing needed.
  # The repo is public on Gitea so no credentials are required for reads.
  local gitea_url="http://${gitea_ip}:3000/${GITEA_USER}/${GITEA_REPO}.git"

  log "Installing Flux into cluster '${CLUSTER_NAME}'..."
  flux install --context "kind-${CLUSTER_NAME}"

  log "Waiting for Flux controllers to be ready..."
  kubectl --context "kind-${CLUSTER_NAME}" \
    -n flux-system wait deployment --all \
    --for=condition=Available \
    --timeout=120s >/dev/null

  log "Configuring GitRepository source → ${gitea_url}"
  flux create source git "${CLUSTER_NAME}" \
    --context "kind-${CLUSTER_NAME}" \
    --url="${gitea_url}" \
    --branch=main \
    --interval="${FLUX_INTERVAL}"

  log "Configuring Kustomization..."
  flux create kustomization "${CLUSTER_NAME}" \
    --context "kind-${CLUSTER_NAME}" \
    --source="GitRepository/${CLUSTER_NAME}" \
    --path="./gitops" \
    --prune=true \
    --interval="${FLUX_INTERVAL}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║       k8s Challenge — Bootstrap      ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  echo ""

  detect_container_engine
  check_prereqs
  setup_git
  setup_network
  start_gitea

  local gitea_ip
  gitea_ip=$(get_gitea_ip)
  info "Gitea container IP on kind network: ${gitea_ip}"

  create_cluster
  install_flux "${gitea_ip}"

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                  Challenge is live!                     ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Flux reconciles every ${FLUX_INTERVAL}. Wait a moment, then:"
  echo ""
  echo -e "  ${CYAN}kubectl get pods -n challenge${NC}"
  echo ""
  echo -e "  After editing a manifest:"
  echo -e "  ${CYAN}git add . && git commit -m \"fix: ...\" && git push origin main${NC}"
  echo -e "  ${CYAN}kubectl get pods -n challenge -w${NC}"
  echo ""
  echo -e "  When done:  ${CYAN}./teardown.sh${NC}"
  echo ""
}

main "$@"
