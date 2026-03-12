#!/usr/bin/env bash
# tailscale-status.sh — show all Tailscale nodes with online/offline status.
#
# Runs locally on Panoptes. Requires tailscale CLI available.
#
# Exit codes:
#   0 — status retrieved
#   1 — tailscale error

set -euo pipefail

echo "=== Tailscale Mesh Status — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo ""

if ! command -v tailscale &>/dev/null; then
  echo "[tailscale-status] ERROR: tailscale CLI not found" >&2
  exit 1
fi

# Get JSON status and format it
status_json=$(tailscale status --json 2>/dev/null) || {
  echo "[tailscale-status] ERROR: failed to get tailscale status" >&2
  exit 1
}

# Show self
echo "--- This Node ---"
echo "$status_json" | jq -r '
  .Self |
  "  \(.HostName) | \(.TailscaleIPs[0]) | OS: \(.OS) | Online: \(.Online)"
'
echo ""

# Show peers
echo "--- Peers ---"
echo "$status_json" | jq -r '
  .Peer | to_entries[] | .value |
  "  \(.HostName) | \(.TailscaleIPs[0]) | OS: \(.OS) | Online: \(.Online) | LastSeen: \(.LastSeen)"
' | sort

echo ""
echo "=== End of Tailscale Status ==="
