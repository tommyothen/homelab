#!/usr/bin/env bash
# digest-audit.sh — report Docker Compose image pinning status.
#
# Runs locally on Panoptes as action-gateway. This is read-only and safe to run
# frequently from OpenClaw via the Action Gateway approval flow.

set -euo pipefail

HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"

if [[ ! "${HOMELAB_DIR}" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
  echo "[digest-audit] ERROR: invalid HOMELAB_DIR format" >&2
  exit 1
fi

SCRIPT_PATH="${HOMELAB_DIR}/scripts/security/compose_digest_manager.py"
if [[ ! -f "${SCRIPT_PATH}" ]]; then
  echo "[digest-audit] ERROR: digest manager script not found at ${SCRIPT_PATH}" >&2
  exit 1
fi

echo "[digest-audit] Running digest scan in ${HOMELAB_DIR}"
python3 "${SCRIPT_PATH}" scan --root "${HOMELAB_DIR}"

echo ""
echo "[digest-audit] Enforcing immutable pin check"
if python3 "${SCRIPT_PATH}" check --root "${HOMELAB_DIR}"; then
  echo "[digest-audit] PASS: all compose images are pinned"
else
  echo "[digest-audit] FAIL: one or more floating image references remain" >&2
  exit 1
fi
