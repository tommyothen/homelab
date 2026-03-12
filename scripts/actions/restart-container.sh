#!/usr/bin/env bash
# restart-container.sh — restart a specific Docker container on a target host.
#
# Parameterized action — expects CONTAINER_NAME and TARGET_HOST as environment
# variables (set by the Action Gateway from request context).
#
# Runs as action-gateway on Panoptes. SSHes to the target host as the deploy
# user. The deploy user must be in the docker group.
#
# Environment variables (required):
#   CONTAINER_NAME   Name of the container to restart
#   TARGET_HOST      Target hostname (must be in allowlist)
#
# Environment overrides (optional):
#   DEPLOY_USER      SSH user on the target host (default: deploy)
#
# Exit codes:
#   0 — container restarted
#   1 — validation or SSH/docker error

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:?ERROR: CONTAINER_NAME is required}"
TARGET_HOST="${TARGET_HOST:?ERROR: TARGET_HOST is required}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"

# Validate container name — alphanumeric, hyphens, underscores only
if [[ ! "${CONTAINER_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[restart-container] ERROR: invalid CONTAINER_NAME format" >&2
  exit 1
fi

# Validate target host — must be an allowed host
readonly ALLOWED_HOSTS="dionysus panoptes"
# shellcheck disable=SC2076 # intentional literal match in space-delimited list
if [[ ! " ${ALLOWED_HOSTS} " =~ " ${TARGET_HOST} " ]]; then
  echo "[restart-container] ERROR: '${TARGET_HOST}' is not in the allowed host list" >&2
  echo "[restart-container] Allowed: ${ALLOWED_HOSTS}" >&2
  exit 1
fi

if [[ ! "${DEPLOY_USER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[restart-container] ERROR: invalid DEPLOY_USER format" >&2
  exit 1
fi

echo "[restart-container] Restarting container '${CONTAINER_NAME}' on ${TARGET_HOST}"
echo "[restart-container] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=10 \
  "${DEPLOY_USER}@${TARGET_HOST}" \
  "docker restart '${CONTAINER_NAME}'"

echo ""
echo "[restart-container] Done. Container '${CONTAINER_NAME}' restarted on ${TARGET_HOST}."
