#!/usr/bin/env bash
# backup-now.sh — trigger an ad-hoc restic backup from Mnemosyne to Oracle.
#
# Runs as action-gateway on Panoptes. SSHes to Mnemosyne as the backup user
# and runs the backup script there.
#
# Prerequisites (one-time setup — see runbooks/offsite-backup.md):
#   1. Create a 'backup' system user on Mnemosyne with shell access.
#   2. Generate an SSH key for the action-gateway user on Panoptes:
#        sudo -u action-gateway ssh-keygen -t ed25519 \
#          -f /var/lib/action-gateway/.ssh/id_ed25519_backup -N ""
#   3. Authorise that key for the backup user on Mnemosyne.
#   4. Ensure /usr/local/bin/run-backup.sh exists on Mnemosyne (see runbook).
#   5. Add Mnemosyne to action-gateway's known_hosts:
#        sudo -u action-gateway ssh-keyscan mnemosyne >> \
#          /var/lib/action-gateway/.ssh/known_hosts
#
# Environment overrides:
#   MNEMOSYNE_HOST   Hostname/IP of Mnemosyne (default: mnemosyne)
#   BACKUP_USER      SSH user on Mnemosyne (default: backup)
#   BACKUP_DATASETS  Comma-separated list of datasets to back up
#                    (default: apps-ssd — the critical one; add media-hdd carefully)
#
# Exit codes:
#   0 — backup completed successfully
#   1 — backup failed

set -euo pipefail

MNEMOSYNE_HOST="${MNEMOSYNE_HOST:-mnemosyne}"
BACKUP_USER="${BACKUP_USER:-backup}"
BACKUP_DATASETS="${BACKUP_DATASETS:-apps-ssd}"

if [[ ! "${MNEMOSYNE_HOST}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "[backup-now] ERROR: invalid hostname format" >&2; exit 1
fi
if [[ ! "${BACKUP_USER}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[backup-now] ERROR: invalid username format" >&2; exit 1
fi
# Only allow known dataset names
for ds in ${BACKUP_DATASETS//,/ }; do
  if [[ ! "$ds" =~ ^(apps-ssd|media-hdd)$ ]]; then
    echo "[backup-now] ERROR: unknown dataset '${ds}' — allowed: apps-ssd, media-hdd" >&2
    exit 1
  fi
done

echo "[backup-now] Triggering ad-hoc backup on ${BACKUP_USER}@${MNEMOSYNE_HOST}"
echo "[backup-now] Datasets: ${BACKUP_DATASETS}"
echo "[backup-now] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

ssh \
  -o StrictHostKeyChecking=yes \
  -o ConnectTimeout=15 \
  -i "/var/lib/action-gateway/.ssh/id_ed25519_backup" \
  "${BACKUP_USER}@${MNEMOSYNE_HOST}" \
  "BACKUP_DATASETS='${BACKUP_DATASETS}' /usr/local/bin/run-backup.sh"

echo ""
echo "[backup-now] Backup job completed. Check Tartarus for snapshot confirmation."
echo "[backup-now] Verify with: scripts/actions/dr-test.sh"
