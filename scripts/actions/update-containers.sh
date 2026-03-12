#!/usr/bin/env bash
# update-containers.sh — pull latest container images and recreate stacks on Dionysus.
#
# Runs as action-gateway on Panoptes. SSHes to Dionysus as the deploy user,
# pulls new images for each compose stack, then recreates containers.
# Plex (media-core) is updated last to minimise downtime.
#
# Required on Dionysus:
#   - deploy user in the docker group (already configured in hosts/dionysus/default.nix)
#   - homelab repo cloned at /opt/homelab (or set HOMELAB_DIR)
#
# Environment overrides (all optional):
#   DIONYSUS_HOST    Hostname/IP of Dionysus (default: dionysus)
#   DEPLOY_USER      SSH user on Dionysus (default: deploy)
#   HOMELAB_DIR      Path to homelab checkout on Dionysus (default: /opt/homelab)
#
# Exit codes:
#   0 — all stacks updated successfully
#   1 — one or more stacks failed

set -euo pipefail

DIONYSUS_HOST="${DIONYSUS_HOST:-dionysus}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"

if [[ ! "${DIONYSUS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[update-containers] ERROR: invalid hostname format" >&2; exit 1
fi
if [[ ! "${DEPLOY_USER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[update-containers] ERROR: invalid username format" >&2; exit 1
fi
if [[ ! "${HOMELAB_DIR}" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
  echo "[update-containers] ERROR: invalid HOMELAB_DIR format" >&2; exit 1
fi

echo "[update-containers] Starting container update on ${DEPLOY_USER}@${DIONYSUS_HOST}"
echo "[update-containers] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Pass HOMELAB_DIR to the remote session; stacks list is baked in here
ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=15 \
  "${DEPLOY_USER}@${DIONYSUS_HOST}" \
  "HOMELAB_DIR='${HOMELAB_DIR}' bash -s" <<'REMOTE'
set -uo pipefail   # no -e: we handle failures manually per stack

# Media-core last so Plex stays up as long as possible
readonly STACKS=(paperless personal books media-extras media-vpn media-core)
FAIL=0

for stack in "${STACKS[@]}"; do
  compose_file="${HOMELAB_DIR}/stacks/dionysus/${stack}/docker-compose.yml"
  if [[ ! -f "${compose_file}" ]]; then
    echo "[update-containers] SKIP: ${compose_file} not found"
    continue
  fi

  echo "[update-containers] Pulling images for ${stack}..."
  if docker compose -f "${compose_file}" pull 2>&1; then
    echo "[update-containers] Recreating ${stack}..."
    if docker compose -f "${compose_file}" up -d --remove-orphans 2>&1; then
      echo "[update-containers] ${stack} — updated OK"
    else
      echo "[update-containers] ERROR: failed to recreate ${stack}" >&2
      FAIL=$((FAIL + 1))
    fi
  else
    echo "[update-containers] ERROR: pull failed for ${stack}" >&2
    FAIL=$((FAIL + 1))
  fi
  echo ""
done

if [[ "${FAIL}" -eq 0 ]]; then
  echo "[update-containers] All stacks updated successfully."
else
  echo "[update-containers] Done with errors: ${FAIL} stack(s) failed." >&2
  exit 1
fi
REMOTE
