# Metis

Metis is the AI co-DevOps engineer for this lab.

## Purpose

- Runs OpenClaw as an intelligent co-DevOps assistant connected to Discord.
- Queries infrastructure via MCP tools (Prometheus, Loki, container status, Tailscale, NixOS generations) on the Homelab MCP Server (Panoptes:8090).
- Receives Alertmanager alerts and Diun image update notifications via OpenClaw webhooks (port 18789, Tailscale-only). Automatically investigates alerts and proposes digest refresh PRs for image updates.
- Requests approved actions through the Panoptes Action Gateway (with reason and context for approvers).
- Proposes infrastructure changes via GitHub PRs (deploy key scoped to homelab repo).
- Proactively monitors for issues: health sweeps, daily reports, disk trend analysis, digest audits.
- Never executes privileged infra actions directly without human approval.
- Cannot approve or merge its own PRs.

## Hardware profile

- Platform: Raspberry Pi 4B (`aarch64-linux`).
- Runtime: Node.js 22 + systemd service (`openclaw`).

## Capabilities

| Capability | Mechanism | Approval required |
|------------|-----------|-------------------|
| Read metrics/logs | MCP tools on Panoptes | No |
| Investigate alerts | OpenClaw webhook (18789) | No |
| Restart containers | Action Gateway | Yes (Discord) |
| NixOS rebuild | Action Gateway | Yes (Discord) |
| Create PR | Git + GitHub CLI | No |
| Merge PR | N/A | Yes (human on GitHub) |
| Deploy after merge | Action Gateway | Yes (Discord) |

## Why the Greek name

Metis is associated with wisdom, strategy, and prudent counsel. That matches this host's role as a careful advisor/operator rather than an autonomous root actor.

## First-run steps

1. Ensure host secrets exist (`hosts/metis/secrets.yaml` — OpenClaw credentials, deploy key, GH token).
2. `sudo nixos-rebuild switch --flake .#metis`
3. `sudo tailscale up`
4. One-time onboarding: `sudo -u metis openclaw onboard`
5. Start service: `sudo systemctl start openclaw`
6. The repo clone oneshot (`metis-repo-clone`) runs automatically on first boot.
7. Configure OpenClaw MCP servers — see `services/metis/OPENCLAW-CONFIG.md`.

## Key files

- `hosts/metis/default.nix`
- `hosts/metis/secrets.yaml`
- `services/metis/mcp-homelab/server.py`
- `services/metis/OPENCLAW-CONFIG.md`
