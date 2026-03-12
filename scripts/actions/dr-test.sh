#!/usr/bin/env bash
# dr-test.sh — disaster recovery readiness check.
#
# Runs locally on Panoptes as the action-gateway user.
# Verifies that the off-site backup chain is intact:
#   1. Tartarus VM is reachable via SSH
#   2. The restic repository is reachable from Tartarus
#   3. The most recent snapshot is listed (proves the repo is intact and decryptable)
#   4. The snapshot age is within an acceptable window
#
# Designed to be run quarterly (or on demand via the 'dr-test' action).
# Also useful after network changes or Tartarus maintenance.
#
# Prerequisites:
#   - SSH key for Tartarus at /var/lib/action-gateway/.ssh/id_ed25519_tartarus
#   - Tartarus host known in action-gateway's known_hosts
#   - restic installed on Tartarus at /usr/local/bin/restic
#   - Backup env file on Tartarus at ~/backup.env (or set TARTARUS_BACKUP_ENV below)
#
# Environment overrides:
#   TARTARUS_HOST        Tartarus public IP or hostname (default: from TARTARUS_IP env)
#   TARTARUS_BACKUP_USER SSH user on Tartarus (default: backup-repo)
#   TARTARUS_BACKUP_ENV  Path to backup.env on Tartarus (default: ~/backup.env)
#   MAX_SNAPSHOT_AGE_H   Max acceptable age of most recent snapshot in hours (default: 26)
#
# Exit codes:
#   0 — all checks passed (DR is ready)
#   1 — one or more checks failed

set -euo pipefail

TARTARUS_HOST="${TARTARUS_HOST:-${TARTARUS_IP:-}}"
TARTARUS_BACKUP_USER="${TARTARUS_BACKUP_USER:-backup-repo}"
TARTARUS_BACKUP_ENV="${TARTARUS_BACKUP_ENV:-~/backup.env}"
MAX_SNAPSHOT_AGE_H="${MAX_SNAPSHOT_AGE_H:-26}"

if [[ -z "${TARTARUS_HOST}" ]]; then
  echo "[dr-test] ERROR: TARTARUS_HOST or TARTARUS_IP must be set in the environment." >&2
  echo "[dr-test] Add TARTARUS_IP to /var/lib/appdata/action-gateway/.env" >&2
  exit 1
fi
if [[ ! "${TARTARUS_HOST}" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
  echo "[dr-test] ERROR: invalid TARTARUS_HOST format" >&2; exit 1
fi
if [[ ! "${MAX_SNAPSHOT_AGE_H}" =~ ^[0-9]+$ ]]; then
  echo "[dr-test] ERROR: MAX_SNAPSHOT_AGE_H must be a positive integer" >&2; exit 1
fi

PASS=0
FAIL=0

check() {
  local name="$1"
  local result="$2"  # "ok" or "fail: <reason>"
  if [[ "$result" == "ok" ]]; then
    echo "  [OK]   ${name}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${name} — ${result#fail: }" >&2
    FAIL=$((FAIL + 1))
  fi
}

echo "=== DR Readiness Check — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo ""

# ---- Check 1: SSH connectivity to Tartarus ----
echo "--- Connectivity ---"
if ssh \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -i "/var/lib/action-gateway/.ssh/id_ed25519_tartarus" \
    "${TARTARUS_BACKUP_USER}@${TARTARUS_HOST}" \
    "echo ok" &>/dev/null; then
  check "Tartarus SSH reachable" "ok"
else
  check "Tartarus SSH reachable" "fail: SSH connection failed"
  echo ""
  echo "Cannot proceed without SSH access. Aborting further checks."
  echo ""
  echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
  exit 1
fi
echo ""

# ---- Check 2: restic repository accessible + list snapshots ----
echo "--- Backup Repository ---"

SNAP_OUTPUT=$(ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=10 \
  -o BatchMode=yes \
  -i "/var/lib/action-gateway/.ssh/id_ed25519_tartarus" \
  "${TARTARUS_BACKUP_USER}@${TARTARUS_HOST}" \
  "MAX_SNAPSHOT_AGE_H='${MAX_SNAPSHOT_AGE_H}' TARTARUS_BACKUP_ENV='${TARTARUS_BACKUP_ENV}' bash -s" <<'REMOTE' 2>&1
set -uo pipefail

if [[ ! -f "${TARTARUS_BACKUP_ENV/#\~/$HOME}" ]]; then
  echo "FAIL_ENV: backup.env not found at ${TARTARUS_BACKUP_ENV}"
  exit 1
fi
source "${TARTARUS_BACKUP_ENV/#\~/$HOME}"

if ! command -v restic &>/dev/null; then
  echo "FAIL_RESTIC: restic not installed on Tartarus"
  exit 1
fi

# List the most recent snapshot
SNAP_JSON=$(restic -r "$RESTIC_REPOSITORY" snapshots --last --json 2>&1)
if echo "$SNAP_JSON" | grep -q '"id"'; then
  echo "OK_SNAP: ${SNAP_JSON}"
else
  echo "FAIL_SNAP: could not list snapshots — repo may be locked or corrupt: ${SNAP_JSON}"
  exit 1
fi
REMOTE
)

if echo "$SNAP_OUTPUT" | grep -q "^FAIL_ENV:"; then
  check "Backup env file on Tartarus" "fail: ${SNAP_OUTPUT#FAIL_ENV: }"
elif echo "$SNAP_OUTPUT" | grep -q "^FAIL_RESTIC:"; then
  check "restic installed on Tartarus" "fail: restic not found"
elif echo "$SNAP_OUTPUT" | grep -q "^FAIL_SNAP:"; then
  check "restic repository accessible" "fail: ${SNAP_OUTPUT#FAIL_SNAP: }"
elif echo "$SNAP_OUTPUT" | grep -q "^OK_SNAP:"; then
  check "restic repository accessible" "ok"

  # Parse snapshot details
  SNAP_JSON=$(echo "$SNAP_OUTPUT" | grep "^OK_SNAP:" | sed 's/^OK_SNAP: //')
  SNAP_ID=$(echo "$SNAP_JSON" | jq -r '.[0].id // "unknown"' 2>/dev/null || echo "unknown")
  SNAP_TIME=$(echo "$SNAP_JSON" | jq -r '.[0].time // "unknown"' 2>/dev/null || echo "unknown")
  SNAP_TAGS=$(echo "$SNAP_JSON" | jq -r '.[0].tags // [] | join(", ")' 2>/dev/null || echo "unknown")

  echo "    Snapshot: ${SNAP_ID:0:8}  Time: ${SNAP_TIME}  Tags: ${SNAP_TAGS}"

  # Check snapshot age
  if [[ "$SNAP_TIME" != "unknown" ]]; then
    SNAP_EPOCH=$(date -d "$SNAP_TIME" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)
    AGE_H=$(( (NOW_EPOCH - SNAP_EPOCH) / 3600 ))
    if [[ "$AGE_H" -le "${MAX_SNAPSHOT_AGE_H}" ]]; then
      check "Most recent snapshot age (${AGE_H}h ≤ ${MAX_SNAPSHOT_AGE_H}h threshold)" "ok"
    else
      check "Most recent snapshot age (${AGE_H}h ≤ ${MAX_SNAPSHOT_AGE_H}h threshold)" \
        "fail: last snapshot is ${AGE_H}h old — backup may not have run"
    fi
  else
    check "Snapshot age check" "fail: could not parse snapshot timestamp"
  fi
else
  check "restic repository check" "fail: unexpected output from Tartarus"
fi

echo ""
echo "=== DR Summary: ${PASS} passed, ${FAIL} failed ==="

if [[ "${FAIL}" -gt 0 ]]; then
  echo ""
  echo "ACTION REQUIRED: Review failures above before the next backup window."
  exit 1
else
  echo ""
  echo "DR check passed. Off-site backups are intact and Tartarus is reachable."
fi
