#!/usr/bin/env bash
# refresh-digests.sh — refresh existing compose digest pins in-place.
#
# Runs locally on Panoptes as action-gateway. Uses pinned-from metadata in
# compose files to refresh digests for the same source tags.

set -euo pipefail

HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"

if [[ ! "${HOMELAB_DIR}" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
  echo "[refresh-digests] ERROR: invalid HOMELAB_DIR format" >&2
  exit 1
fi

SCRIPT_PATH="${HOMELAB_DIR}/scripts/security/compose_digest_manager.py"
if [[ ! -f "${SCRIPT_PATH}" ]]; then
  echo "[refresh-digests] ERROR: digest manager script not found at ${SCRIPT_PATH}" >&2
  exit 1
fi

echo "[refresh-digests] Refreshing pinned digests in ${HOMELAB_DIR}"
python3 "${SCRIPT_PATH}" refresh --root "${HOMELAB_DIR}" --write

echo ""
echo "[refresh-digests] Re-running immutable pin check"
python3 "${SCRIPT_PATH}" check --root "${HOMELAB_DIR}"

echo ""
echo "[refresh-digests] Done. Review git diff and open a PR before deployment."
