#!/usr/bin/env bash
# health-check.sh — full-stack health check across homelab services.
#
# Checks the following and prints a summary:
#   - Plex HTTP (via Tailscale/LAN)
#   - Gatus container running on Panoptes
#   - Prometheus /-/healthy
#   - Grafana /api/health
#   - Dionysus SSH reachability
#
# Exits 0 if all checks pass, 1 if any fail.
#
# Environment overrides (all optional — defaults assume Tailscale hostnames):
#   DIONYSUS_HOST, PLEX_URL, PROMETHEUS_URL, GRAFANA_URL, PANOPTES_HOST

set -euo pipefail

DIONYSUS_HOST="${DIONYSUS_HOST:-dionysus}"
PLEX_URL="${PLEX_URL:-http://dionysus:32400/web}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://panoptes:9090/-/healthy}"
GRAFANA_URL="${GRAFANA_URL:-http://panoptes:3000/api/health}"
PANOPTES_HOST="${PANOPTES_HOST:-panoptes}"

# Validate inputs to prevent injection via environment overrides.
validate_url() {
  local url="$1"
  if [[ ! "$url" =~ ^https?://[a-zA-Z0-9.:/_-]+$ ]]; then
    echo "[health-check] ERROR: invalid URL format: $url" >&2
    exit 1
  fi
}
validate_host() {
  local host="$1"
  if [[ ! "$host" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "[health-check] ERROR: invalid hostname format: $host" >&2
    exit 1
  fi
}

validate_host "$DIONYSUS_HOST"
validate_host "$PANOPTES_HOST"
validate_url "$PLEX_URL"
validate_url "$PROMETHEUS_URL"
validate_url "$GRAFANA_URL"

PASS=0
FAIL=0

check_http() {
  local name="$1"
  local url="$2"
  local expected_code="${3:-200}"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
  if [ "$code" = "$expected_code" ]; then
    echo "  [OK]   ${name} (HTTP ${code})"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${name} — expected HTTP ${expected_code}, got ${code} (url: ${url})"
    FAIL=$((FAIL + 1))
  fi
}

check_ssh() {
  local name="$1"
  local host="$2"
  # Requires host to be in known_hosts: ssh-keyscan <host> >> ~action-gateway/.ssh/known_hosts
  if ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o BatchMode=yes \
       "deploy@${host}" "echo ok" &>/dev/null; then
    echo "  [OK]   ${name} (SSH reachable)"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${name} (SSH unreachable)"
    FAIL=$((FAIL + 1))
  fi
}

check_container() {
  local name="$1"
  local container="$2"
  local host="$3"
  local running
  running=$(ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=5 -o BatchMode=yes \
       "deploy@${host}" "docker inspect --format='{{.State.Running}}' '${container}'" 2>/dev/null || echo "false")
  if [ "$running" = "true" ]; then
    echo "  [OK]   ${name} (container running)"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${name} (container not running on ${host})"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Homelab Health Check — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo ""

echo "--- HTTP endpoints ---"
check_http "Plex Web"     "$PLEX_URL"       "200"
check_http "Prometheus"   "$PROMETHEUS_URL"  "200"
check_http "Grafana"      "$GRAFANA_URL"     "200"

echo ""
echo "--- Container checks ---"
check_container "Gatus" "gatus" "$PANOPTES_HOST"

echo ""
echo "--- SSH reachability ---"
check_ssh "Dionysus" "$DIONYSUS_HOST"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
