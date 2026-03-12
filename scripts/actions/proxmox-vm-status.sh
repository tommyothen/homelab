#!/usr/bin/env bash
# proxmox-vm-status.sh — list all Proxmox VMs with status, CPU, and memory.
#
# Queries the Proxmox VE API via the prometheus-pve-exporter's underlying
# connection, or directly via the PVE API if credentials are available.
#
# Environment overrides:
#   ZEUS_HOST        Proxmox host (default: zeus)
#   PVE_NODE         PVE node name (default: zeus)
#   PVE_TOKEN_ID     PVE API token ID (e.g. prometheus@pve!metrics)
#   PVE_TOKEN_VALUE  PVE API token value
#
# Exit codes:
#   0 — status retrieved
#   1 — API error

set -euo pipefail

ZEUS_HOST="${ZEUS_HOST:-zeus}"
PVE_NODE="${PVE_NODE:-zeus}"
PVE_TOKEN_ID="${PVE_TOKEN_ID:-}"
PVE_TOKEN_VALUE="${PVE_TOKEN_VALUE:-}"

if [[ ! "${ZEUS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[proxmox-vm-status] ERROR: invalid ZEUS_HOST format" >&2
  exit 1
fi

if [[ -z "${PVE_TOKEN_ID}" || -z "${PVE_TOKEN_VALUE}" ]]; then
  echo "[proxmox-vm-status] ERROR: PVE_TOKEN_ID and PVE_TOKEN_VALUE are required" >&2
  echo "[proxmox-vm-status] Set them in the action-gateway .env file" >&2
  exit 1
fi

echo "=== Proxmox VM Status — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo ""

# Query the PVE API for QEMU VMs
response=$(curl -sf --max-time 15 \
  -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_VALUE}" \
  --insecure \
  "https://${ZEUS_HOST}:8006/api2/json/nodes/${PVE_NODE}/qemu" 2>/dev/null) || {
  echo "[proxmox-vm-status] ERROR: failed to reach Proxmox API at ${ZEUS_HOST}:8006" >&2
  exit 1
}

echo "$response" | jq -r '
  .data | sort_by(.vmid) | .[] |
  "  VMID \(.vmid) | \(.name) | Status: \(.status) | CPU: \(.cpus) cores | Memory: \(.maxmem / 1073741824 | floor)GB | Uptime: \(.uptime / 3600 | floor)h"
'

echo ""
echo "=== End of VM Status ==="
