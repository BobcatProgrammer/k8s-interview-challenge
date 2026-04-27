#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="challenge"
GITEA_CONTAINER="kind-interview-gitea"
CONTAINER_ENGINE=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

# Detect the same engine that was used during bootstrap
detect_container_engine() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    CONTAINER_ENGINE="podman"
    export KIND_EXPERIMENTAL_PROVIDER=podman
  else
    # Best-effort: fall back to whichever binary exists
    CONTAINER_ENGINE=$(command -v docker || command -v podman || echo "docker")
  fi
}

detect_container_engine

# Remove Gitea FIRST so that kind can cleanly remove the shared 'kind' network
log "Stopping Gitea container..."
$CONTAINER_ENGINE rm -f "${GITEA_CONTAINER}" >/dev/null 2>&1 \
  || warn "Gitea container not found — skipping."

log "Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null \
  || warn "Cluster '${CLUSTER_NAME}' not found — skipping."

# Remove the kind network if kind left it behind (e.g. cluster never fully started)
$CONTAINER_ENGINE network rm kind >/dev/null 2>&1 \
  || true

log "Removing git remote 'origin'..."
git -C "${SCRIPT_DIR}" remote remove origin 2>/dev/null \
  || warn "Remote 'origin' not found — skipping."

echo ""
echo -e "${GREEN}[+] Teardown complete.${NC}"
echo ""
