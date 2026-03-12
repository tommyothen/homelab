#!/usr/bin/env bash
# restart-plex.sh — restart the Plex container on Dionysus.
#
# Runs as the action-gateway system user on Panoptes. That user must have an
# SSH key authorised on Dionysus for the deploy user, and the deploy user must
# have passwordless sudo access for the specific docker command only.
#
# Sudoers entry on Dionysus (narrow scope):
#   deploy ALL=(root) NOPASSWD: /usr/bin/docker restart plex
#
# Exit codes:
#   0 — Plex restarted successfully
#   1 — SSH or docker error

set -euo pipefail

DIONYSUS_HOST="${DIONYSUS_HOST:-dionysus}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
CONTAINER_NAME="${CONTAINER_NAME:-plex}"

# Validate inputs to prevent command injection.
readonly ALLOWED_CONTAINERS="plex sonarr radarr sabnzbd"
if [[ ! " ${ALLOWED_CONTAINERS} " =~ " ${CONTAINER_NAME} " ]]; then
  echo "[restart-plex] ERROR: container '${CONTAINER_NAME}' not in allowlist (${ALLOWED_CONTAINERS})" >&2
  exit 1
fi
if [[ ! "${DIONYSUS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[restart-plex] ERROR: invalid hostname format" >&2
  exit 1
fi
if [[ ! "${DEPLOY_USER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[restart-plex] ERROR: invalid username format" >&2
  exit 1
fi

echo "[restart-plex] Connecting to ${DEPLOY_USER}@${DIONYSUS_HOST}..."

# Requires Dionysus to be in the action-gateway user's known_hosts.
# First-time setup: ssh-keyscan dionysus >> ~action-gateway/.ssh/known_hosts
ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=10 \
  "${DEPLOY_USER}@${DIONYSUS_HOST}" \
  "sudo docker restart '${CONTAINER_NAME}'"

echo "[restart-plex] Done. Plex container '${CONTAINER_NAME}' restarted on ${DIONYSUS_HOST}."
