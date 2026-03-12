# Panoptes

Panoptes is the operations control plane for the homelab.

## Purpose

- Runs native Prometheus, Grafana, Alertmanager, and node exporter.
- Alertmanager routes alerts to Metis's OpenClaw webhook over Tailscale for automated investigation.
- Diun sends image update notifications to both Discord and Metis's OpenClaw webhook.
- Hosts ingress stack (Traefik, Authentik, Gatus, Homepage, and related services).
- Runs the Action Gateway so Metis can request human-approved operations.
- Runs the Homelab MCP Server (port 8090) providing read-only observability tools for Metis.

## Hardware profile

- Platform: NixOS VM on Zeus (`x86_64-linux`).
- Storage model: NFS-mounted appdata from Mnemosyne.
- Network role: split ingress endpoint (Tailscale for admin routes, LAN for selected home routes).

## Why the Greek name

Argus Panoptes means "all-seeing." This is the monitoring and visibility hub, so the name fits the observability mission.

## First-run steps

1. `sudo nixos-rebuild switch --flake .#panoptes`
2. `sudo tailscale up`
3. Clone the repo for compose files: `sudo git clone https://github.com/tommyothen/homelab.git /opt/homelab`
4. Restart ingress stack: `sudo systemctl restart ingress`
5. Action Gateway starts automatically; check `sudo systemctl status action-gateway`
6. MCP server starts automatically after rebuild (systemd `multi-user.target`)

See `runbooks/deployment-gotchas.md` for common issues.

## Key files

- `hosts/panoptes/default.nix`
- `hosts/panoptes/services/action-gateway.nix`
- `hosts/panoptes/services/mcp-homelab.nix`
- `hosts/panoptes/services/stacks.nix`
- `stacks/panoptes/ingress/docker-compose.yml`
- `services/metis/mcp-homelab/server.py`
