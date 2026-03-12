#!/usr/bin/env bash
# rotate-logs.sh — find and truncate oversized Docker container log files on Dionysus.
#
# Runs as action-gateway on Panoptes. SSHes to Dionysus as the deploy user.
# Docker log files live at /var/lib/docker/containers/<id>/<id>-json.log.
# These are owned by root, so truncation requires sudo.
#
# In normal operation the json-file logging driver's max-size/max-file options
# cap log growth automatically. This script handles any containers that bypass
# that config (e.g., containers created without log rotation settings).
#
# Required sudoers on Dionysus (deploy user):
#   deploy ALL=(root) NOPASSWD: /usr/bin/find /var/lib/docker/containers -name *-json.log -size *
#   deploy ALL=(root) NOPASSWD: /usr/bin/truncate -s 0 /var/lib/docker/containers/*/*-json.log
#   deploy ALL=(root) NOPASSWD: /bin/ls -lah /var/lib/docker/containers
#
# Add to hosts/dionysus/default.nix security.sudo.extraRules.
#
# Environment overrides:
#   DIONYSUS_HOST      Hostname/IP of Dionysus (default: dionysus)
#   DEPLOY_USER        SSH user on Dionysus (default: deploy)
#   SIZE_THRESHOLD     Minimum log size before truncation, in MB (default: 100)
#   DRY_RUN            If "true", report but do not truncate (default: false)
#
# Exit codes:
#   0 — completed (oversized logs truncated, or none found)
#   1 — SSH or execution error

set -euo pipefail

DIONYSUS_HOST="${DIONYSUS_HOST:-dionysus}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
SIZE_THRESHOLD="${SIZE_THRESHOLD:-100}"
DRY_RUN="${DRY_RUN:-false}"

if [[ ! "${DIONYSUS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[rotate-logs] ERROR: invalid hostname format" >&2; exit 1
fi
if [[ ! "${DEPLOY_USER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[rotate-logs] ERROR: invalid username format" >&2; exit 1
fi
if [[ ! "${SIZE_THRESHOLD}" =~ ^[0-9]+$ ]]; then
  echo "[rotate-logs] ERROR: SIZE_THRESHOLD must be a positive integer" >&2; exit 1
fi

echo "[rotate-logs] Checking Docker log sizes on ${DIONYSUS_HOST} (threshold: ${SIZE_THRESHOLD}MB, dry_run: ${DRY_RUN})"
echo "[rotate-logs] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=15 \
  "${DEPLOY_USER}@${DIONYSUS_HOST}" \
  "SIZE_THRESHOLD='${SIZE_THRESHOLD}' DRY_RUN='${DRY_RUN}' bash -s" <<'REMOTE'
set -euo pipefail

FOUND=0
TRUNCATED=0

echo "--- Scanning container log files ---"

# Find log files larger than the threshold
while IFS= read -r logfile; do
  FOUND=$((FOUND + 1))
  size=$(du -sh "$logfile" 2>/dev/null | cut -f1)

  # Get container name from docker inspect
  container_id=$(echo "$logfile" | awk -F'/' '{print $6}')
  container_name=$(docker ps -a --filter "id=${container_id}" --format "{{.Names}}" 2>/dev/null || echo "unknown")

  echo "  OVERSIZED: ${container_name} (${size}) — ${logfile}"

  if [[ "${DRY_RUN}" != "true" ]]; then
    sudo truncate -s 0 "$logfile"
    echo "  TRUNCATED: ${container_name}"
    TRUNCATED=$((TRUNCATED + 1))
  fi
done < <(sudo find /var/lib/docker/containers -name "*-json.log" -size "+${SIZE_THRESHOLD}M" 2>/dev/null)

echo ""
if [[ "$FOUND" -eq 0 ]]; then
  echo "No oversized log files found (all under ${SIZE_THRESHOLD}MB)."
elif [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry run: found ${FOUND} oversized log(s). Re-run with DRY_RUN=false to truncate."
else
  echo "Truncated ${TRUNCATED}/${FOUND} oversized log file(s)."
fi
REMOTE
