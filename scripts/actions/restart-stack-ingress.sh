#!/usr/bin/env bash
# restart-stack-ingress.sh — restart the ingress stack on Panoptes.
#
# Runs locally on Panoptes as the action-gateway user. The deploy user must
# be in the docker group to run docker compose without sudo.
#
# Environment overrides:
#   HOMELAB_DIR      Path to homelab checkout (default: /opt/homelab)
#
# Exit codes:
#   0 — stack restarted successfully
#   1 — compose error

set -euo pipefail

HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"

if [[ ! "${HOMELAB_DIR}" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
  echo "[restart-stack-ingress] ERROR: invalid HOMELAB_DIR format" >&2
  exit 1
fi

COMPOSE_FILE="${HOMELAB_DIR}/stacks/panoptes/ingress/docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[restart-stack-ingress] ERROR: ${COMPOSE_FILE} not found" >&2
  exit 1
fi

echo "[restart-stack-ingress] Restarting ingress stack on Panoptes"
echo "[restart-stack-ingress] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

docker compose -f "$COMPOSE_FILE" restart

echo ""
echo "[restart-stack-ingress] Container status after restart:"
docker compose -f "$COMPOSE_FILE" ps --format "table {{.Name}}\t{{.Status}}"

echo ""
echo "[restart-stack-ingress] Done."
