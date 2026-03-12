#!/usr/bin/env bash
# rebuild-host.sh — run nixos-rebuild switch on a target NixOS host.
#
# Runs as action-gateway on Panoptes. SSHes to the target as the deploy user,
# checks out a specific branch/tag on the homelab repo, then runs nixos-rebuild switch.
#
# ---------------------------------------------------------------------------
# SECURITY NOTE — git pull and nixos-rebuild trust
# ---------------------------------------------------------------------------
# This script does:  git fetch + git checkout HOMELAB_BRANCH + nixos-rebuild switch
#
# That means: whatever is on HOMELAB_BRANCH on the remote gets applied to production
# automatically once a human approves the rebuild action.
#
# Threat model:
#   - A bad push to the deploy branch (accident or compromised GitHub account)
#     would be applied to the fleet on the next approved rebuild.
#   - Mitigation: use a separate 'deploy' branch (not 'main') that you promote
#     deliberately by running: git push origin main:deploy
#   - This gives you one explicit human decision between "code merged" and "fleet updated."
#   - Set HOMELAB_BRANCH=deploy in /var/lib/appdata/action-gateway/.env to activate this.
#
# Default (HOMELAB_BRANCH=main) is convenient for a single-person homelab but be aware
# of the above. At minimum, protect main with required reviews if the repo is shared.
# ---------------------------------------------------------------------------
#
# Required sudoers on each target host (deploy user):
#   deploy ALL=(root) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild switch *
#   deploy ALL=(root) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild --flake *
#
# Add to each host's default.nix:
#   security.sudo.extraRules = [{
#     users = [ "deploy" ];
#     commands = [{
#       command = "/run/current-system/sw/bin/nixos-rebuild *";
#       options = [ "NOPASSWD" ];
#     }];
#   }];
#
# Environment overrides (all optional):
#   REBUILD_TARGET   Hostname of the NixOS host to rebuild (default: dionysus)
#   DEPLOY_USER      SSH user on target (default: deploy)
#   HOMELAB_DIR      Path to homelab checkout on target (default: /opt/homelab)
#   HOMELAB_BRANCH   Branch or tag to check out before rebuilding (default: main)
#                    Recommend setting to 'deploy' and promoting deliberately.
#
# Exit codes:
#   0 — rebuild succeeded
#   1 — rebuild failed

set -euo pipefail

REBUILD_TARGET="${REBUILD_TARGET:-dionysus}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
HOMELAB_BRANCH="${HOMELAB_BRANCH:-main}"

# Allowed rebuild targets — prevents accidental rebuilds of unexpected hosts
readonly ALLOWED_TARGETS="cerberus dionysus panoptes metis"
if [[ ! " ${ALLOWED_TARGETS} " =~ " ${REBUILD_TARGET} " ]]; then
  echo "[rebuild-host] ERROR: '${REBUILD_TARGET}' is not an allowed rebuild target" >&2
  echo "[rebuild-host] Allowed: ${ALLOWED_TARGETS}" >&2
  exit 1
fi
if [[ ! "${DEPLOY_USER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[rebuild-host] ERROR: invalid username format" >&2
  exit 1
fi
if [[ ! "${HOMELAB_DIR}" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
  echo "[rebuild-host] ERROR: invalid HOMELAB_DIR format" >&2
  exit 1
fi
if [[ ! "${HOMELAB_BRANCH}" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
  echo "[rebuild-host] ERROR: invalid HOMELAB_BRANCH format" >&2
  exit 1
fi

echo "[rebuild-host] Rebuilding ${REBUILD_TARGET} via ${DEPLOY_USER}@${REBUILD_TARGET}"
echo "[rebuild-host] Branch: ${HOMELAB_BRANCH}"
echo "[rebuild-host] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=15 \
  "${DEPLOY_USER}@${REBUILD_TARGET}" \
  "HOMELAB_DIR='${HOMELAB_DIR}' REBUILD_TARGET='${REBUILD_TARGET}' HOMELAB_BRANCH='${HOMELAB_BRANCH}' bash -s" <<'REMOTE'
set -euo pipefail

echo "[rebuild-host] Fetching ${HOMELAB_BRANCH}..."
git -C "${HOMELAB_DIR}" fetch origin
git -C "${HOMELAB_DIR}" checkout "${HOMELAB_BRANCH}"
git -C "${HOMELAB_DIR}" reset --hard "origin/${HOMELAB_BRANCH}"

echo "[rebuild-host] Running nixos-rebuild switch (flake: ${HOMELAB_DIR}#${REBUILD_TARGET})..."
sudo nixos-rebuild switch --flake "${HOMELAB_DIR}#${REBUILD_TARGET}"

echo "[rebuild-host] Rebuild complete."
REMOTE

echo ""
echo "[rebuild-host] Done. ${REBUILD_TARGET} is running the latest config."
