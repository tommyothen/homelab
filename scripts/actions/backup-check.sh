#!/usr/bin/env bash
# backup-check.sh — check TrueNAS snapshot ages and alert if stale.
#
# Runs locally on Panoptes as the action-gateway user.
# Queries the TrueNAS API for the most recent snapshot on each pool,
# computes the age, and exits 1 if any snapshot is older than the threshold.
#
# Designed for Phase 1 Metis monitoring: read-only, high value, no side effects.
# Metis can call this periodically and alert if the exit code is non-zero.
#
# Environment overrides:
#   TRUENAS_HOST           TrueNAS hostname/IP (default: mnemosyne)
#   TRUENAS_API_KEY        TrueNAS API key (required — set in action-gateway .env)
#   MAX_AGE_HOURS_APPSSD   Max acceptable snapshot age for apps-ssd, in hours (default: 25)
#   MAX_AGE_HOURS_MEDIAHDD Max acceptable snapshot age for media-hdd, in hours (default: 25)
#
# Exit codes:
#   0 — all snapshots within acceptable age
#   1 — one or more snapshots are stale, or API is unreachable

set -euo pipefail

TRUENAS_HOST="${TRUENAS_HOST:-mnemosyne}"
TRUENAS_API_KEY="${TRUENAS_API_KEY:-}"
MAX_AGE_HOURS_APPSSD="${MAX_AGE_HOURS_APPSSD:-25}"
MAX_AGE_HOURS_MEDIAHDD="${MAX_AGE_HOURS_MEDIAHDD:-25}"

if [[ -z "${TRUENAS_API_KEY}" ]]; then
  echo "[backup-check] ERROR: TRUENAS_API_KEY is not set." >&2
  echo "[backup-check] Add it to /var/lib/appdata/action-gateway/.env" >&2
  exit 1
fi
if [[ ! "${TRUENAS_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[backup-check] ERROR: invalid TRUENAS_HOST format" >&2; exit 1
fi
if [[ ! "${MAX_AGE_HOURS_APPSSD}" =~ ^[0-9]+$ ]] || \
   [[ ! "${MAX_AGE_HOURS_MEDIAHDD}" =~ ^[0-9]+$ ]]; then
  echo "[backup-check] ERROR: MAX_AGE_HOURS must be a positive integer" >&2; exit 1
fi

NOW_EPOCH=$(date +%s)
FAIL=0

check_pool() {
  local pool="$1"
  local max_hours="$2"
  local max_seconds=$(( max_hours * 3600 ))

  # Get the most recent snapshot's creation time (Unix epoch)
  snap_json=$(curl -sf --max-time 15 \
    -H "Authorization: Bearer ${TRUENAS_API_KEY}" \
    "http://${TRUENAS_HOST}/api/v2.0/zfs/snapshot?pool=${pool}&limit=1&order_by=-snapshot_name" \
    2>/dev/null) || {
      echo "[backup-check] FAIL: could not reach TrueNAS API for pool '${pool}'" >&2
      return 1
    }

  snap_name=$(echo "$snap_json" | jq -r '.[0].name // "none"')
  if [[ "$snap_name" == "none" || "$snap_name" == "null" ]]; then
    echo "[backup-check] FAIL: no snapshots found on pool '${pool}'" >&2
    return 1
  fi

  # TrueNAS API returns creation as a Unix timestamp in properties.creation.rawvalue
  snap_epoch=$(echo "$snap_json" | jq -r '.[0].properties.creation.rawvalue // "0"')
  if [[ "$snap_epoch" == "0" || "$snap_epoch" == "null" ]]; then
    echo "[backup-check] WARN: could not parse snapshot timestamp for '${snap_name}'" >&2
    return 1
  fi

  age_seconds=$(( NOW_EPOCH - snap_epoch ))
  age_hours=$(( age_seconds / 3600 ))

  if [[ "$age_seconds" -gt "$max_seconds" ]]; then
    echo "[backup-check] STALE: ${pool} — last snapshot '${snap_name}' is ${age_hours}h old (max: ${max_hours}h)" >&2
    return 1
  else
    echo "[backup-check] OK: ${pool} — last snapshot '${snap_name}' is ${age_hours}h old"
  fi
}

echo "[backup-check] Checking TrueNAS snapshot ages on ${TRUENAS_HOST}"
echo "[backup-check] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

check_pool "apps-ssd"  "${MAX_AGE_HOURS_APPSSD}"  || FAIL=1
check_pool "media-hdd" "${MAX_AGE_HOURS_MEDIAHDD}" || FAIL=1

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "[backup-check] All pools have recent snapshots."
else
  echo "[backup-check] ALERT: One or more pools have stale snapshots!" >&2
  exit 1
fi
