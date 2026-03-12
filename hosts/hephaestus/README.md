# Hephaestus

Hephaestus is the dedicated game server host.

## Purpose

- Runs Pterodactyl Wings for game server lifecycle management.
- Hosts Pterodactyl Panel stack (via Docker Compose) for administration.
- Exposes game ports publicly while keeping admin surfaces on Tailscale.

## Hardware profile

- Platform: OCI ARM free tier (`aarch64-linux`).
- Capacity target: 3 OCPU, 18 GB RAM, 150 GB storage.
- Runtime: Docker plus systemd-managed Wings daemon.

## Why the Greek name

Hephaestus is the divine smith and builder. This host "forges" and runs containerized game worlds, so the name aligns with crafting/building infrastructure.

## First-run steps

1. `sudo nixos-rebuild switch --flake .#hephaestus`
2. `sudo tailscale up --auth-key=<key>`
3. Start panel stack: `sudo systemctl start pterodactyl`
4. Generate Wings node config in Panel and place it at `/etc/pterodactyl/config.yml`
5. `sudo systemctl start pterodactyl-wings`

## Security note

This host is intentionally isolated from Tartarus backup storage to limit blast radius if a game stack is compromised.

## Key files

- `hosts/hephaestus/default.nix`
- `hosts/hephaestus/services/stacks.nix`
- `stacks/hephaestus/pterodactyl/docker-compose.yml`
