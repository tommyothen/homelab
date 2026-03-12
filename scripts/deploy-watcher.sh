#!/usr/bin/env bash
# deploy-watcher.sh — poll origin/main and request rebuilds for changed hosts.
#
# Runs on Metis as the metis user via a systemd timer (every 5 minutes).
# Compares the last-deployed SHA with origin/main HEAD. If new commits are
# found, maps changed paths to rebuild actions and POSTs them to the Action
# Gateway for human approval.
#
# Required environment:
#   ACTION_GATEWAY_URL    Base URL of the Action Gateway (e.g. http://panoptes:8080)
#   ACTION_GATEWAY_TOKEN  Bearer token for authentication
#
# Optional overrides:
#   REPO_DIR    Path to the homelab repo (default: /var/lib/metis/homelab)
#   STATE_FILE  Path to the last-deployed SHA file (default: /var/lib/metis/.last-deployed-sha)
#
# Exit codes:
#   0 — success (whether or not rebuilds were requested)
#   1 — missing required environment variables

set -euo pipefail

REPO_DIR="${REPO_DIR:-/var/lib/metis/homelab}"
STATE_FILE="${STATE_FILE:-/var/lib/metis/.last-deployed-sha}"

log() { echo "[deploy-watcher] $*"; }

# ---------------------------------------------------------------------------
# Validate required env
# ---------------------------------------------------------------------------
if [[ -z "${ACTION_GATEWAY_URL:-}" ]]; then
  log "ERROR: ACTION_GATEWAY_URL is not set" >&2
  exit 1
fi
if [[ -z "${ACTION_GATEWAY_TOKEN:-}" ]]; then
  log "ERROR: ACTION_GATEWAY_TOKEN is not set" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fetch latest from origin
# ---------------------------------------------------------------------------
if ! git -C "${REPO_DIR}" fetch origin 2>/dev/null; then
  log "git fetch failed — will retry next cycle"
  exit 0
fi

NEW_SHA="$(git -C "${REPO_DIR}" rev-parse origin/main)"

# ---------------------------------------------------------------------------
# First run — seed state file, no rebuilds
# ---------------------------------------------------------------------------
if [[ ! -f "${STATE_FILE}" ]]; then
  log "First run — seeding state file with ${NEW_SHA}"
  echo "${NEW_SHA}" > "${STATE_FILE}"
  exit 0
fi

OLD_SHA="$(cat "${STATE_FILE}")"

# ---------------------------------------------------------------------------
# No new commits
# ---------------------------------------------------------------------------
if [[ "${OLD_SHA}" == "${NEW_SHA}" ]]; then
  exit 0
fi

log "New commits detected: ${OLD_SHA:0:7}..${NEW_SHA:0:7}"

# ---------------------------------------------------------------------------
# Gather changed files and commit summary
# ---------------------------------------------------------------------------
CHANGED_FILES="$(git -C "${REPO_DIR}" diff --name-only "${OLD_SHA}..${NEW_SHA}")"
COMMIT_LOG="$(git -C "${REPO_DIR}" log --oneline "${OLD_SHA}..${NEW_SHA}")"

log "Changed files:"
echo "${CHANGED_FILES}" | while IFS= read -r f; do echo "  ${f}"; done

# ---------------------------------------------------------------------------
# Map paths → actions
# ---------------------------------------------------------------------------
declare -A ACTIONS=()

while IFS= read -r file; do
  [[ -z "${file}" ]] && continue

  case "${file}" in
    hosts/cerberus/*)           ACTIONS[rebuild-cerberus]=1 ;;
    hosts/dionysus/*)           ACTIONS[rebuild-dionysus]=1 ;;
    hosts/panoptes/*)           ACTIONS[rebuild-panoptes]=1 ;;
    hosts/metis/*)              ACTIONS[rebuild-metis]=1 ;;
    modules/* | flake.nix | flake.lock)
      ACTIONS[rebuild-cerberus]=1
      ACTIONS[rebuild-dionysus]=1
      ACTIONS[rebuild-panoptes]=1
      ACTIONS[rebuild-metis]=1
      ;;
    stacks/dionysus/*)          ACTIONS[update-containers]=1 ;;
    scripts/actions/* | services/action-gateway/*)
                                ACTIONS[rebuild-panoptes]=1 ;;
    services/metis/* | packages/openclaw/*)
                                ACTIONS[rebuild-metis]=1 ;;
    # stacks/hephaestus/*, docs, terraform, etc. — no action
  esac
done <<< "${CHANGED_FILES}"

# ---------------------------------------------------------------------------
# No actionable changes — update SHA and exit
# ---------------------------------------------------------------------------
if [[ ${#ACTIONS[@]} -eq 0 ]]; then
  log "No actionable changes — updating SHA only"
  echo "${NEW_SHA}" > "${STATE_FILE}"
  exit 0
fi

log "Actions to request: ${!ACTIONS[*]}"

# ---------------------------------------------------------------------------
# POST each action to the Action Gateway
# ---------------------------------------------------------------------------
for action in "${!ACTIONS[@]}"; do
  reason="Deploy watcher: new commits on main (${OLD_SHA:0:7}..${NEW_SHA:0:7})\n${COMMIT_LOG}"

  if [[ "${action}" == "rebuild-dionysus" ]]; then
    reason="${reason}\n\nNote: Plex runs on Dionysus. If this is during peak hours (evenings/weekends), consider deferring approval."
  fi

  # Build JSON payload with jq to handle escaping
  payload="$(jq -n --arg reason "${reason}" '{"reason": $reason}')"

  log "Requesting ${action}..."
  http_code="$(curl -s -o /dev/stderr -w '%{http_code}' \
    -X POST "${ACTION_GATEWAY_URL}/action/${action}" \
    -H "Authorization: Bearer ${ACTION_GATEWAY_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>&1)" || true

  log "${action} → HTTP ${http_code}"
done

# ---------------------------------------------------------------------------
# Update state file
# ---------------------------------------------------------------------------
echo "${NEW_SHA}" > "${STATE_FILE}"
log "State updated to ${NEW_SHA:0:7}"
