#!/usr/bin/env bash
# restart-stack.sh — restart a Docker Compose stack on Dionysus.
#
# Runs as action-gateway on Panoptes. SSHes to Dionysus as the deploy user.
# The deploy user is in the docker group and can run docker compose without sudo.
#
# Environment overrides:
#   DIONYSUS_HOST    Hostname/IP of Dionysus (default: dionysus)
#   DEPLOY_USER      SSH user on Dionysus (default: deploy)
#   STACK_NAME       Name of the compose stack to restart (default: media-core)
#   HOMELAB_DIR      Path to homelab checkout on Dionysus (default: /opt/homelab)
#
# Exit codes:
#   0 — stack restarted successfully
#   1 — SSH or compose error

set -euo pipefail

DIONYSUS_HOST="${DIONYSUS_HOST:-dionysus}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
STACK_NAME="${STACK_NAME:-media-core}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"

# Allowlist of stacks that can be restarted via this action
readonly ALLOWED_STACKS="media-core media-vpn media-extras books personal paperless"
if [[ ! " ${ALLOWED_STACKS} " =~ " ${STACK_NAME} " ]]; then
  echo "[restart-stack] ERROR: '${STACK_NAME}' is not in the allowed stack list" >&2
  echo "[restart-stack] Allowed: ${ALLOWED_STACKS}" >&2
  exit 1
fi
if [[ ! "${DIONYSUS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[restart-stack] ERROR: invalid hostname format" >&2; exit 1
fi
if [[ ! "${DEPLOY_USER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[restart-stack] ERROR: invalid username format" >&2; exit 1
fi
if [[ ! "${HOMELAB_DIR}" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
  echo "[restart-stack] ERROR: invalid HOMELAB_DIR format" >&2; exit 1
fi

echo "[restart-stack] Restarting stack '${STACK_NAME}' on ${DEPLOY_USER}@${DIONYSUS_HOST}"
echo "[restart-stack] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=15 \
  "${DEPLOY_USER}@${DIONYSUS_HOST}" \
  "STACK_NAME='${STACK_NAME}' HOMELAB_DIR='${HOMELAB_DIR}' bash -s" <<'REMOTE'
set -euo pipefail

compose_file="${HOMELAB_DIR}/stacks/dionysus/${STACK_NAME}/docker-compose.yml"
if [[ ! -f "$compose_file" ]]; then
  echo "[restart-stack] ERROR: ${compose_file} not found" >&2
  exit 1
fi

echo "[restart-stack] Restarting all containers in ${STACK_NAME}..."
docker compose -f "$compose_file" restart

echo "[restart-stack] Container status after restart:"
docker compose -f "$compose_file" ps --format "table {{.Name}}\t{{.Status}}"
REMOTE

echo ""
echo "[restart-stack] Done. Stack '${STACK_NAME}' restarted."
