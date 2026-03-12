# Action Scripts

Executable scripts that the Action Gateway may run after explicit human approval.

## Categories

- **Health/reporting:** `health-check.sh`, `daily-report.sh`, `backup-check.sh`, `dr-test.sh`
- **Service operations:** `restart-plex.sh`, `restart-stack-{media,books,personal,paperless}.sh`, `restart-stack-ingress.sh`, `restart-container.sh`, `update-containers.sh`
  - `restart-stack.sh` and `rebuild-host.sh` are internal helpers called by the per-host/per-stack wrapper scripts; they are not registered in `actions.yaml`.
- **Platform operations:** `rebuild-{cerberus,dionysus,panoptes,metis}.sh`, `rotate-logs.sh`
- **Supply-chain checks:** `digest-audit.sh`, `refresh-digests.sh`
- **Backup operations:** `backup-now.sh`
- **Infrastructure status:** `proxmox-vm-status.sh`, `tailscale-status.sh`, `cert-status.sh`, `truenas-snapshot-status.sh`
- **Metis operations:** `sync-metis-repo.sh`

## Parameterized scripts

Some scripts accept parameters as environment variables, validated by the Action Gateway's `params` schema in `actions.yaml`:

- `restart-container.sh` — requires `CONTAINER_NAME` and `TARGET_HOST`

## Contract

- Every script here should be deterministic and auditable.
- Action names and script mappings must stay in sync with `services/action-gateway/actions.yaml`.
- All scripts use `set -euo pipefail`, validate inputs, and use `StrictHostKeyChecking=yes` for SSH.
