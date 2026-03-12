# Dionysus

Dionysus is the media and personal-apps workload host.

## Purpose

- Runs Plex, Arr stack, download clients, books pipeline, personal tools, and Paperless.
- Mounts NFS storage from Mnemosyne for media and appdata.
- Keeps almost all service ports Tailscale-only (Plex is the LAN exception).

## Hardware profile

- Platform: NixOS VM on Zeus (`x86_64-linux`).
- Storage model: NFS mounts + optional local SSD partition for in-progress downloads.
- Acceleration: Intel Quick Sync passthrough support for transcoding.

## Why the Greek name

Dionysus is linked with festivity and leisure, which maps naturally to the entertainment/media role of this machine.

## First-run steps

1. `sudo nixos-rebuild switch --flake .#dionysus`
2. `sudo tailscale up`
3. Clone the repo for compose files: `sudo git clone https://github.com/tommyothen/homelab.git /opt/homelab`
4. Confirm NFS mounts from Mnemosyne. If Docker fails with "mkdir permission denied", set **Maproot User/Group** to `root` on the TrueNAS NFS exports.
5. Restart stacks: `sudo systemctl restart media-core media-vpn media-extras books personal paperless`
6. If Promtail fails with NAMESPACE error: `sudo mkdir -p /var/lib/promtail && sudo systemctl restart promtail`

See `runbooks/deployment-gotchas.md` for common issues.

## Key files

- `hosts/dionysus/default.nix`
- `hosts/dionysus/services/stacks.nix`
- `stacks/dionysus/*/docker-compose.yml`
