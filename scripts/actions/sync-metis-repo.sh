#!/usr/bin/env bash
# sync-metis-repo.sh — pull latest main branch on Metis's local repo clone.
#
# Runs from Panoptes as action-gateway user, SSHes to Metis as the metis user.
# Resets the local clone to match origin/main exactly.
#
# Environment overrides:
#   METIS_HOST       Hostname/IP of Metis (default: metis)
#   METIS_USER       SSH user on Metis (default: metis)
#   REPO_DIR         Path to the repo on Metis (default: /var/lib/metis/homelab)
#
# Exit codes:
#   0 — repo synced
#   1 — SSH or git error

set -euo pipefail

METIS_HOST="${METIS_HOST:-metis}"
METIS_USER="${METIS_USER:-metis}"
REPO_DIR="${REPO_DIR:-/var/lib/metis/homelab}"

if [[ ! "${METIS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[sync-metis-repo] ERROR: invalid METIS_HOST format" >&2
  exit 1
fi
if [[ ! "${METIS_USER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[sync-metis-repo] ERROR: invalid METIS_USER format" >&2
  exit 1
fi
if [[ ! "${REPO_DIR}" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
  echo "[sync-metis-repo] ERROR: invalid REPO_DIR format" >&2
  exit 1
fi

echo "[sync-metis-repo] Syncing homelab repo on ${METIS_USER}@${METIS_HOST}:${REPO_DIR}"
echo "[sync-metis-repo] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=10 \
  "${METIS_USER}@${METIS_HOST}" \
  "cd '${REPO_DIR}' && git fetch origin && git reset --hard origin/main && git log --oneline -3"

echo ""
echo "[sync-metis-repo] Done. Repo synced to latest main."
