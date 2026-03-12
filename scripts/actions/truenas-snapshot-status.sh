#!/usr/bin/env bash
# truenas-snapshot-status.sh — list recent snapshots across TrueNAS pools.
#
# Queries the TrueNAS API for the most recent snapshots on each dataset.
#
# Environment overrides:
#   TRUENAS_HOST     TrueNAS hostname/IP (default: mnemosyne)
#   TRUENAS_API_KEY  TrueNAS API key (required)
#
# Exit codes:
#   0 — snapshot info retrieved
#   1 — API error or missing credentials

set -euo pipefail

TRUENAS_HOST="${TRUENAS_HOST:-mnemosyne}"
TRUENAS_API_KEY="${TRUENAS_API_KEY:-}"

if [[ ! "${TRUENAS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[truenas-snapshot-status] ERROR: invalid TRUENAS_HOST format" >&2
  exit 1
fi

if [[ -z "${TRUENAS_API_KEY}" ]]; then
  echo "[truenas-snapshot-status] ERROR: TRUENAS_API_KEY is required" >&2
  echo "[truenas-snapshot-status] Set it in the action-gateway .env file" >&2
  exit 1
fi

echo "=== TrueNAS Snapshot Status — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo ""

# Fetch all snapshots, ordered by creation descending
response=$(curl -sf --max-time 15 \
  -H "Authorization: Bearer ${TRUENAS_API_KEY}" \
  "http://${TRUENAS_HOST}/api/v2.0/zfs/snapshot?limit=100&order_by=-properties.creation.rawvalue" \
  2>/dev/null) || {
  echo "[truenas-snapshot-status] ERROR: failed to reach TrueNAS API at ${TRUENAS_HOST}" >&2
  exit 1
}

# Group by dataset and show the latest snapshot for each
echo "$response" | jq -r '
  group_by(.dataset) | .[] |
  "  Dataset: \(.[0].dataset)\n    Latest: \(.[0].name)\n    Created: \(.[0].properties.creation.value)\n    Count: \(length) snapshots\n"
'

echo "=== End of Snapshot Status ==="
