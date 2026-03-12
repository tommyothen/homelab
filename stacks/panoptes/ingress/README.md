# Panoptes Ingress Stack

Entry point for web access, auth, service status pages, and the homelab map.

## Purpose

- Terminates TLS and routes `*.0x21.uk` requests via Traefik.
- Applies Authentik forward-auth policy to protected services.
- Publishes status/dashboard/map views through Gatus, Homepage (`dash.0x21.uk`), and Homelab Hub.

Traefik uses split entrypoints:

- Tailscale entrypoints for admin/control-plane routes.
- LAN entrypoints for selected home-facing routes (`home.0x21.uk`, `plex.0x21.uk`, `seerr.0x21.uk`).

## Important directories

- `traefik/`: static and dynamic route configuration.
- `gatus/`: declarative health-check definitions.
- `homepage/`: dashboard layout, widgets, and links.
- `homelab-hub`: inventory + topology map service (data persisted in `/var/lib/appdata/homelab-hub`).

## Additional services in this stack

- **Authentik** — SSO/identity provider (authentik-server, authentik-worker, authentik-postgresql, authentik-redis, docker-proxy).
- **Notifiarr** — Arr stack notifications to Discord.
- **Diun** — Docker image update notifier (Discord + OpenClaw webhook).
- **Speedtest Tracker** — ISP speed history with Prometheus metrics.
- **Miniflux** — Private RSS reader (miniflux + miniflux-postgresql).
- **pve-exporter** — Prometheus exporter for Proxmox VE metrics.

## Lifecycle

Manage this stack via the Panoptes systemd unit:

```bash
sudo systemctl start ingress
```

Tailscale and LAN IP variables are injected by NixOS from `net.*` in `flake.nix`.
