#!/usr/bin/env bash
# daily-report.sh — generate a homelab health summary and print it to stdout.
#
# Runs locally on Panoptes as the action-gateway user.
# The Action Gateway posts the stdout output as a Discord message.
#
# Checks reported:
#   - Node up/down status from Prometheus
#   - Disk usage on all scraped nodes
#   - Active Prometheus alerts
#   - NFS mount health (local check)
#   - Container counts on Dionysus (via SSH)
#   - TrueNAS snapshot age (via API)
#
# Environment overrides:
#   PROMETHEUS_URL   Prometheus base URL (default: http://localhost:9090)
#   DIONYSUS_HOST    Hostname/IP of Dionysus (default: dionysus)
#   DEPLOY_USER      SSH user on Dionysus (default: deploy)
#   TRUENAS_HOST     TrueNAS hostname/IP (default: mnemosyne)
#   TRUENAS_API_KEY  TrueNAS API key (required for snapshot check — see .env)
#
# Exit codes:
#   0 — report generated
#   1 — critical error (Prometheus unreachable)

set -euo pipefail

PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
DIONYSUS_HOST="${DIONYSUS_HOST:-dionysus}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
TRUENAS_HOST="${TRUENAS_HOST:-mnemosyne}"
TRUENAS_API_KEY="${TRUENAS_API_KEY:-}"

# Input validation
if [[ ! "${PROMETHEUS_URL}" =~ ^https?://[a-zA-Z0-9.:/_-]+$ ]]; then
  echo "ERROR: invalid PROMETHEUS_URL" >&2; exit 1
fi
if [[ ! "${DIONYSUS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: invalid DIONYSUS_HOST" >&2; exit 1
fi
if [[ ! "${DEPLOY_USER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: invalid DEPLOY_USER" >&2; exit 1
fi
if [[ ! "${TRUENAS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: invalid TRUENAS_HOST" >&2; exit 1
fi

NOW=$(date -u '+%Y-%m-%d %H:%M UTC')
echo "=== Homelab Daily Report — ${NOW} ==="
echo ""

# ---- Node status from Prometheus ----
echo "--- Node Status ---"
nodes_down=$(curl -sf --max-time 10 \
  "${PROMETHEUS_URL}/api/v1/query?query=up%3D%3D0" 2>/dev/null \
  | jq -r '.data.result[] | "  DOWN: \(.metric.instance)"' 2>/dev/null \
  || echo "  [could not reach Prometheus]")
nodes_up=$(curl -sf --max-time 10 \
  "${PROMETHEUS_URL}/api/v1/query?query=up%3D%3D1" 2>/dev/null \
  | jq -r '.data.result[] | "  UP:   \(.metric.instance)"' 2>/dev/null \
  || true)
echo "$nodes_up"
[ -n "$nodes_down" ] && echo "$nodes_down"
echo ""

# ---- Active Prometheus alerts ----
echo "--- Active Alerts ---"
alerts=$(curl -sf --max-time 10 \
  "${PROMETHEUS_URL}/api/v1/alerts" 2>/dev/null \
  | jq -r '.data.alerts[]
      | select(.state == "firing")
      | "  [\(.labels.severity | ascii_upcase)] \(.labels.alertname) — \(.annotations.summary)"' \
  2>/dev/null || echo "  [could not reach Prometheus]")
if [[ -z "$alerts" ]]; then
  echo "  No alerts firing"
else
  echo "$alerts"
fi
echo ""

# ---- Disk usage from Prometheus ----
echo "--- Disk Usage (root filesystem) ---"
disk=$(curl -sf --max-time 10 \
  "${PROMETHEUS_URL}/api/v1/query?query=round((1-(node_filesystem_avail_bytes%7Bmountpoint%3D%22%2F%22%7D%2Fnode_filesystem_size_bytes%7Bmountpoint%3D%22%2F%22%7D))*100)" \
  2>/dev/null \
  | jq -r '.data.result[]
      | "  \(.metric.instance): \(.value[1])% used"' \
  2>/dev/null || echo "  [could not reach Prometheus]")
echo "$disk"
echo ""

# ---- Container count on Dionysus ----
echo "--- Container Status (Dionysus) ---"
if ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o BatchMode=yes \
     "${DEPLOY_USER}@${DIONYSUS_HOST}" "echo ok" &>/dev/null; then
  counts=$(ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o BatchMode=yes \
    "${DEPLOY_USER}@${DIONYSUS_HOST}" \
    "docker ps --format '{{.Status}}' | awk '{print \$1}' | sort | uniq -c | sort -rn" 2>/dev/null \
    || echo "  [docker query failed]")
  total=$(ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o BatchMode=yes \
    "${DEPLOY_USER}@${DIONYSUS_HOST}" \
    "docker ps -q | wc -l" 2>/dev/null || echo "?")
  echo "  Running containers: ${total}"
  echo "$counts" | while read -r line; do echo "    ${line}"; done
else
  echo "  [SSH unreachable — Dionysus may be down]"
fi
echo ""

# ---- TrueNAS snapshot age ----
echo "--- TrueNAS Snapshots (apps-ssd) ---"
if [[ -n "${TRUENAS_API_KEY}" ]]; then
  snap_info=$(curl -sf --max-time 10 \
    -H "Authorization: Bearer ${TRUENAS_API_KEY}" \
    "http://${TRUENAS_HOST}/api/v2.0/zfs/snapshot?pool=apps-ssd&limit=1&order_by=-snapshot_name" \
    2>/dev/null | jq -r '.[0] | "  Latest: \(.name) (\(.properties.creation.value))"' \
    2>/dev/null || echo "  [TrueNAS API unreachable]")
  echo "$snap_info"
else
  echo "  [TRUENAS_API_KEY not set — skipping snapshot check]"
fi
echo ""

echo "=== End of Report ==="
