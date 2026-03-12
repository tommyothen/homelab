# Runbook: Off-Site Backups (Mnemosyne -> Tartarus)

> **Scope:** Configure encrypted restic backups from Mnemosyne (TrueNAS) to Tartarus (OCI).
>
> **Primary target:** `apps-ssd` dataset first; add `media-hdd` later if bandwidth/storage allow.
>
> **Last reviewed:** 2026-03-05

---

## Architecture

```text
Mnemosyne (TrueNAS)
  -> restic backup script
  -> encrypts client-side
  -> uploads over SSH

Tartarus (OCI)
  -> stores encrypted restic repository blobs
  -> cannot read plaintext without restic password
```

Tartarus remains isolated from Hephaestus by design. See `hosts/tartarus/default.nix`.

---

## Prerequisites

- Tartarus deployed with reachable SSH
- `backup-repo` user configured in `hosts/tartarus/default.nix`
- Mnemosyne shell access as `root`
- Destination dataset path available on Mnemosyne (`/mnt/apps-ssd/appdata/backup`)

---

## 1) Tartarus setup

### 1.1 Confirm backup user and repository paths

Expected structure on Tartarus:

```text
/data/restic/
  mnemosyne/
    apps-ssd/
    media-hdd/
```

### 1.2 Confirm SSH path is open

- Verify Tartarus firewall allows TCP 22
- Verify OCI Security List allows inbound TCP 22

Stop-check:

- `backup-repo@<tartarus-ip>` is reachable over SSH.

---

## 2) Mnemosyne setup

### 2.1 Install restic

```bash
mkdir -p /usr/local/bin
curl -Lo /tmp/restic.bz2 \
  "https://github.com/restic/restic/releases/latest/download/restic_linux_arm64.bz2"
# Use linux_amd64.bz2 on x86 systems
bunzip2 /tmp/restic.bz2
chmod +x /tmp/restic
mv /tmp/restic /usr/local/bin/restic
restic version
```

Note: TrueNAS updates may remove `/usr/local/bin` custom binaries.

### 2.2 Generate backup SSH key on Mnemosyne

```bash
mkdir -p /root/.ssh
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_tartarus -N "" -C "mnemosyne-backup"
cat /root/.ssh/id_ed25519_tartarus.pub
```

### 2.3 Authorize key on Tartarus

Add public key to `backup-repo` user in `hosts/tartarus/default.nix`:

```nix
users.users.backup-repo = {
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA... mnemosyne-backup"
  ];
};
```

Redeploy Tartarus:

```bash
nixos-rebuild switch --flake .#tartarus --target-host backup-repo@<tartarus-ip> --build-host localhost
```

### 2.4 Verify SSH key auth from Mnemosyne

```bash
ssh -i /root/.ssh/id_ed25519_tartarus \
  -o StrictHostKeyChecking=accept-new \
  backup-repo@<tartarus-ip> echo "connection OK"
```

### 2.5 Create restic env file

```bash
mkdir -p /mnt/apps-ssd/appdata/backup
cat > /mnt/apps-ssd/appdata/backup/backup.env <<'EOF'
RESTIC_REPOSITORY=sftp:backup-repo@<tartarus-ip>:/data/restic/mnemosyne/apps-ssd
RESTIC_PASSWORD=<strong-passphrase>
SSH_KEY=/root/.ssh/id_ed25519_tartarus
EOF
chmod 600 /mnt/apps-ssd/appdata/backup/backup.env
```

### 2.6 Initialize repository

```bash
source /mnt/apps-ssd/appdata/backup/backup.env
restic -r "$RESTIC_REPOSITORY" \
  -o sftp.command="ssh -i $SSH_KEY -o StrictHostKeyChecking=yes" \
  init
```

Stop-check:

- `restic snapshots` returns successfully (may be empty immediately after init).

---

## 3) Create backup script

```bash
cat > /usr/local/bin/run-backup.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/mnt/apps-ssd/appdata/backup/backup.env"
source "$ENV_FILE"

BACKUP_DATASETS="${BACKUP_DATASETS:-apps-ssd}"

RESTIC_CMD="restic -r $RESTIC_REPOSITORY -o sftp.command=\"ssh -i $SSH_KEY -o StrictHostKeyChecking=yes\""

for dataset in ${BACKUP_DATASETS//,/ }; do
  case "$dataset" in
    apps-ssd)  BACKUP_PATH="/mnt/apps-ssd/appdata" ;;
    media-hdd) BACKUP_PATH="/mnt/media-hdd/media" ;;
    *)
      echo "Unknown dataset: $dataset" >&2
      continue
      ;;
  esac

  eval "$RESTIC_CMD" backup "$BACKUP_PATH" \
    --tag "$dataset" \
    --exclude="*.tmp" \
    --exclude="*.log" \
    --one-file-system
done

eval "$RESTIC_CMD" forget --prune \
  --keep-hourly 24 \
  --keep-daily 30 \
  --keep-weekly 12 \
  --keep-monthly 6
SCRIPT

chmod +x /usr/local/bin/run-backup.sh
```

Retention policy:

- Hourly: 24
- Daily: 30
- Weekly: 12
- Monthly: 6

Adjust for Tartarus storage budget.

---

## 4) Schedule backups

### Option A (recommended): TrueNAS cron job

- Command: `/usr/local/bin/run-backup.sh >> /var/log/restic-backup.log 2>&1`
- Schedule: daily (example `03:00`)
- User: `root`

### Option B: systemd timer

```bash
cat > /etc/systemd/system/restic-backup.service <<'EOF'
[Unit]
Description=Restic backup to Tartarus
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/run-backup.sh
EOF

cat > /etc/systemd/system/restic-backup.timer <<'EOF'
[Unit]
Description=Daily restic backup to Tartarus

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now restic-backup.timer
systemctl list-timers restic-backup.timer
```

Note: TrueNAS upgrades may remove unit files in `/etc/systemd/system`.

---

## 5) Validate restore path

### 5.1 List snapshots

```bash
source /mnt/apps-ssd/appdata/backup/backup.env
restic -r "$RESTIC_REPOSITORY" \
  -o sftp.command="ssh -i $SSH_KEY -o StrictHostKeyChecking=yes" \
  snapshots
```

### 5.2 Restore latest snapshot to staging

```bash
SNAPSHOT_ID=$(restic -r "$RESTIC_REPOSITORY" \
  -o sftp.command="ssh -i $SSH_KEY -o StrictHostKeyChecking=yes" \
  snapshots --last --json | jq -r '.[0].id')

mkdir -p /tmp/restore-test
restic -r "$RESTIC_REPOSITORY" \
  -o sftp.command="ssh -i $SSH_KEY -o StrictHostKeyChecking=yes" \
  restore "$SNAPSHOT_ID" \
  --target /tmp/restore-test \
  --path /mnt/apps-ssd/appdata

ls /tmp/restore-test/mnt/apps-ssd/appdata/
rm -rf /tmp/restore-test
```

Stop-check:

- Restore test confirms key app data is recoverable.

---

## 6) Monitoring integration

- `backup-check` Action Gateway action checks snapshot age via TrueNAS API and sends Discord alerts
- Add `TRUENAS_API_KEY` to `hosts/panoptes/secrets.yaml` under `action_gateway_secrets`
- Encrypt and redeploy Panoptes

Reference deploy flow:

```bash
# nix run nixpkgs#sops -- hosts/panoptes/secrets.yaml
# nixos-rebuild switch --flake .#panoptes
```

Schedule daily Action Gateway `/action/backup-check` calls via Metis.

---

## Troubleshooting

Lock stuck:

```bash
restic -r "$RESTIC_REPOSITORY" unlock
```

Repo stats / emergency retention trim:

```bash
restic -r "$RESTIC_REPOSITORY" stats
restic -r "$RESTIC_REPOSITORY" forget --prune --keep-last 10
```

Integrity check:

```bash
restic -r "$RESTIC_REPOSITORY" check
```
