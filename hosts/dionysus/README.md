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
3. Confirm NFS mounts from Mnemosyne.
4. Start stacks: `sudo systemctl start media-core media-vpn media-extras books personal paperless`

## Key files

- `hosts/dionysus/default.nix`
- `hosts/dionysus/services/stacks.nix`
- `stacks/dionysus/*/docker-compose.yml`
