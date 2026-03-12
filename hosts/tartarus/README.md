# Tartarus

Tartarus is the off-site, encrypted backup target.

## Purpose

- Receives restic snapshots over SSH/SFTP from Mnemosyne.
- Stays minimal by design: no Docker and almost no public attack surface.
- Provides disaster recovery separation from the home network.

## Hardware profile

- Platform: OCI ARM free tier (`aarch64-linux`).
- Capacity target: 1 OCPU, 6 GB RAM, 50 GB storage.
- Network model: public SSH plus Tailscale for admin/metrics.

## Why the Greek name

Tartarus represents a deep, isolated place. That maps to this host's role as a separated backup vault outside the primary lab.

## First-run steps

1. `sudo nixos-rebuild switch --flake .#tartarus`
2. `sudo tailscale up --auth-key=<key>`
3. Add backup SSH public key to `backup-repo` authorized keys.
4. Follow `runbooks/offsite-backup.md` for repository bootstrap and policy.

## Key files

- `hosts/tartarus/default.nix`
- `hosts/tartarus/hardware-configuration.nix`
- `runbooks/offsite-backup.md`
