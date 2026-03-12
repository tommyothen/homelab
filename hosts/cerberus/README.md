# Cerberus

Cerberus is the DNS and traffic-gating host for the homelab.

## Purpose

- Runs AdGuard Home as the authoritative resolver for LAN clients.
- Publishes split DNS rewrites for `*.0x21.uk`.
- Keeps admin UIs on Tailscale-only ingress while allowing `home`, `plex`, and `seerr` on LAN ingress.

## Hardware profile

- Platform: Raspberry Pi 4B (`aarch64-linux`).
- Network role: static LAN address (`net.hosts.cerberus`) plus Tailscale.

## Why the Greek name

Cerberus guarded the gate to the Underworld. This host similarly guards network entry points by controlling DNS and where traffic can resolve.

## First-run steps

1. Sync repo to host (if local-only): `rsync -av --delete --no-owner --no-group ~/Programming/homelab/ root@<cerberus-lan-ip>:/root/homelab/`
2. `sudo nixos-rebuild switch --flake "path:/root/homelab#cerberus"`
3. `sudo tailscale up`
4. Open `http://<cerberus-tailscale-ip>:3000` from a Tailscale client and set the AdGuard admin password.

If you use `nix shell` on a fresh host and get `experimental Nix feature 'nix-command' is disabled`, add:

`nix --extra-experimental-features "nix-command flakes" ...`

## Key files

- `hosts/cerberus/default.nix`
- `hosts/cerberus/hardware-configuration.nix`
