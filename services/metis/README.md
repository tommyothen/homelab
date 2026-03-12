# Metis Service Assets

This directory contains service-level assets for the Metis/OpenClaw node.

## Contents

- `mcp-homelab/`: Python MCP server providing read-only observability tools for Metis. Deployed as a systemd service on Panoptes (port 8090, Tailscale-only). Tools include Prometheus queries, Loki log search, container status, NixOS generations, Gatus uptime, Tailscale mesh status, and disk usage.
- `OPENCLAW-CONFIG.md`: Configuration guide covering MCP server setup in `openclaw.json`, webhook configuration for Alertmanager/Diun integration, system prompt additions for proactive monitoring, and cron task schedules for health sweeps, daily reports, digest audits, and flake lock checks.

## Runtime credentials

Managed via sops-nix. See `hosts/metis/secrets.yaml` for required keys:
- `openclaw_secrets` — OpenClaw gateway token, Discord bot token, Anthropic API key, Action Gateway URL/token
- `github_deploy_key` — SSH deploy key scoped to the homelab repo (read/write)
- `gh_token` — Fine-grained GitHub PAT (contents:write + pull_requests:write, no approve)
