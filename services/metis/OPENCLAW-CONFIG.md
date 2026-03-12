# OpenClaw Configuration for Metis

This document describes the OpenClaw configuration needed to enable Metis as a
co-DevOps engineer with MCP-based observability, git-based changes, and
proactive monitoring.

## MCP Server Configuration

Add to `~/.openclaw/openclaw.json` on Metis (path: `/var/lib/metis/.config/openclaw/openclaw.json`):

```json
{
  "models": {
    "default": "openai-codex/gpt-5.4",
    "providers": [
      {
        "id": "openai-codex",
        "api": "openai-completions"
      }
    ]
  },
  "mcpServers": {
    "homelab": {
      "url": "http://<PANOPTES_TAILSCALE_IP>:8090",
      "transport": "streamable-http"
    },
    "filesystem": {
      "command": "npx",
      "args": [
        "-y",
        "@anthropic/mcp-filesystem",
        "/var/lib/metis/homelab"
      ]
    },
    "git": {
      "command": "npx",
      "args": [
        "-y",
        "@anthropic/mcp-git",
        "--repository",
        "/var/lib/metis/homelab"
      ]
    }
  }
}
```

### First-Run Auth (OpenAI Codex OAuth)

After deploying, complete the one-time device OAuth flow:

```bash
# Run on Metis (requires browser on another device):
sudo -u metis openclaw models login openai-codex
# → prints a device code + URL → open URL, sign in with ChatGPT account
# Token persists in /var/lib/metis/.config/openclaw/ across reboots/rebuilds
```

Verify the login succeeded:

```bash
sudo -u metis openclaw models list   # confirm gpt-5.4 is listed
sudo -u metis openclaw chat "hello"  # quick smoke test
```

> **Note:** `gpt-5.4` is the current Codex model ID. Run `openclaw models list` after
> login to confirm available model IDs if the default fails.

## System Prompt Additions

Add these sections to the OpenClaw system prompt to enable proactive monitoring
behavior:

```
## Infrastructure Observability

You have access to the homelab MCP server with read-only tools:
- prometheus_query / prometheus_query_range — PromQL queries for metrics
- prometheus_alerts — check firing alerts
- loki_query — search logs via LogQL
- container_status — Docker container state on any host
- nixos_generations — NixOS generation history
- gatus_status — endpoint uptime monitoring
- tailscale_status — mesh network health
- disk_usage — disk utilization across all hosts

Use these tools to investigate issues, generate reports, and monitor trends.
Always check metrics before recommending actions.

## Git-Based Changes

You can propose infrastructure changes via pull requests:
1. Sync repo: request "sync-metis-repo" action first
2. Create branch: git checkout -b metis/<description>
3. Edit files using filesystem MCP tools
4. Commit: git commit -m "metis: <description>"
5. Push: git push origin metis/<description>
6. Create PR: use gh CLI (GH_TOKEN is in your environment)
7. Post PR link to Discord for human review
8. After human merges, request the appropriate rebuild action

You can NEVER approve or merge your own PRs. A human must review and merge.

## Action Gateway

Request infrastructure actions via POST to the Action Gateway. Include:
- reason: why you're requesting this action
- context: parameters (if the action accepts them)

The action must be approved by a human in Discord before it executes.
You can check action status via GET /action/{action_id}.

## Safety Rules

- NEVER bypass approval gates
- NEVER modify production systems directly
- Always explain your reasoning before requesting destructive actions
- Plex uptime is the top priority — avoid actions that risk Plex during peak hours
- When investigating alerts, gather evidence first, then suggest remediation
```

## Scheduled Tasks (Cron Configuration)

Configure these in OpenClaw's task scheduler:

| Schedule | Task | Description |
|----------|------|-------------|
| Every 6h | Health sweep | Query `up == 0`, check disk trends, verify Plex is serving |
| Daily 08:00 UTC | Smart daily report | Query Prometheus + Loki via MCP, analyze 7-day trends, post to Discord |
| Weekly Mon 09:00 UTC | Digest audit | Check for stale image pins, auto-create refresh PR if needed |
| Weekly Sun 22:00 UTC | Backup verification | Request backup-check + dr-test actions, report results |
| Every 12h | Disk trend analysis | 7-day disk usage trend via prometheus_query_range, alert if any host fills within 14 days |
| Weekly Wed 09:00 UTC | Flake lock check | Check flake.lock age, create update PR if older than 14 days |
| Every 5m | Deploy watcher | systemd timer runs `deploy-watcher.sh` — no AI tokens consumed |

### Deploy Watcher (systemd timer + shell script)

Implemented as a shell script (`scripts/deploy-watcher.sh`) running via a
systemd timer on Metis every 5 minutes — **not** an OpenClaw cron. This avoids
wasting AI tokens on purely deterministic logic. Rebuild requests still flow
through the Action Gateway's Discord approval, so Metis (OpenClaw) sees them
naturally.

**Script:** `scripts/deploy-watcher.sh`
**NixOS config:** `hosts/metis/default.nix` (systemd service + timer)
**State file:** `/var/lib/metis/.last-deployed-sha`

**How it works:**

1. `git fetch origin` in `/var/lib/metis/homelab`
2. Compare SHA in state file vs `origin/main` HEAD
3. First run (no state file): seed with current SHA, exit without rebuilds
4. If unchanged: exit silently
5. If changed: `git diff --name-only` → map paths to actions:

   | Path pattern                   | Action(s)                              |
   |--------------------------------|----------------------------------------|
   | hosts/cerberus/**              | rebuild-cerberus                       |
   | hosts/dionysus/**              | rebuild-dionysus                       |
   | hosts/panoptes/**              | rebuild-panoptes                       |
   | hosts/metis/**                 | rebuild-metis                          |
   | modules/**                     | rebuild all: cerberus, dionysus, panoptes, metis |
   | flake.nix                      | rebuild all: cerberus, dionysus, panoptes, metis |
   | flake.lock                     | rebuild all: cerberus, dionysus, panoptes, metis |
   | stacks/dionysus/**             | update-containers                      |
   | stacks/hephaestus/**           | no action (OCI, managed separately)    |
   | scripts/actions/**             | rebuild-panoptes                       |
   | services/action-gateway/**     | rebuild-panoptes                       |
   | services/metis/**              | rebuild-metis                          |
   | packages/openclaw/**           | rebuild-metis                          |
   | Other (docs, terraform, etc.)  | no action needed                       |

6. Deduplicate and POST each action to the Action Gateway (with commit summary as reason)
7. Update state file to new SHA (always, even if no actions triggered)

**Env vars** (from `openclaw_secrets` EnvironmentFile): `ACTION_GATEWAY_URL`, `ACTION_GATEWAY_TOKEN`

**Verification:**
```bash
sudo systemctl status deploy-watcher.timer   # confirm timer is active
sudo journalctl -u deploy-watcher            # check logs
```

**Rebuild allowlist:** cerberus, dionysus, panoptes, metis. Tartarus and
Hephaestus are OCI hosts managed separately and are intentionally excluded.

### Smart Daily Report Workflow

Instead of just running the daily-report.sh script, Metis should:

1. Use `prometheus_query` to get current node status (up/down)
2. Use `prometheus_query_range` for 7-day CPU, memory, disk, network trends
3. Compare current values to 24h and 7d averages
4. Use `loki_query` for recent error log patterns
5. Use `container_status` on dionysus and panoptes
6. Highlight anomalies (e.g., "Dionysus disk usage +3% in 24h vs 0.5%/day average")
7. Suggest remediation if needed (e.g., "Consider running rotate-logs")
8. Post formatted report to Discord

### Alert-Driven Investigation (via OpenClaw Webhooks)

Alertmanager and Diun POST directly to OpenClaw's webhook endpoint on Metis
(`http://<METIS_TAILSCALE_IP>:18789/hooks/*`). This triggers an agent turn with
structured context — no Discord message parsing required.

Add the following `hooks` block to `openclaw.json`:

```json
{
  "gateway": {
    "port": 18789,
    "bind": "tailnet"
  },
  "hooks": {
    "enabled": true,
    "token": "${OPENCLAW_HOOKS_TOKEN}",
    "path": "/hooks",
    "allowedAgentIds": ["main"],
    "defaultSessionKey": "hook:ingress",
    "allowRequestSessionKey": false,
    "allowedSessionKeyPrefixes": ["hook:"],
    "mappings": [
      {
        "name": "alertmanager",
        "match": { "path": "alertmanager" },
        "action": "agent",
        "wakeMode": "now",
        "deliver": true,
        "channel": "discord",
        "messageTemplate": "[ALERT] Status: {{status}}. {{#alerts}}Alert: {{labels.alertname}} on {{labels.instance}} ({{labels.severity}}). Summary: {{annotations.summary}}. {{/alerts}}Investigate using MCP tools and post findings to Discord."
      },
      {
        "name": "diun",
        "match": { "path": "diun" },
        "action": "agent",
        "wakeMode": "now",
        "deliver": true,
        "channel": "discord",
        "messageTemplate": "[IMAGE UPDATE] {{image.name}}:{{image.tag}} has a new version (status: {{status}}, platform: {{image.platform}}). Check if pinned in the homelab repo and create a digest refresh PR if so."
      }
    ]
  }
}
```

**Token:** `OPENCLAW_HOOKS_TOKEN` is injected via the `openclaw_secrets` EnvironmentFile
(sops-nix). OpenClaw reads it through env var interpolation in the JSON config.

**Security:** The gateway binds to the Tailscale interface only. Port 18789 is open
on `tailscale0` in the NixOS firewall. Bearer token auth on every request.

**Testing:**

```bash
# From any Tailscale host, test alertmanager webhook:
curl -X POST http://<METIS_TAILSCALE_IP>:18789/hooks/alertmanager \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"status":"firing","alerts":[{"labels":{"alertname":"TestAlert","instance":"localhost:9100","severity":"warning"},"annotations":{"summary":"Test alert from curl"}}]}'

# Test diun webhook:
curl -X POST http://<METIS_TAILSCALE_IP>:18789/hooks/diun \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"status":"new","image":{"name":"traefik","tag":"v3.3","platform":"linux/amd64"}}'
```

**Deployment sequence:**
1. Generate a random token: `openssl rand -hex 32`
2. Set the same value in `hosts/metis/secrets.yaml` (`openclaw_secrets`), `hosts/panoptes/secrets.yaml` (`alertmanager_hooks_token` + `ingress_secrets`)
3. Encrypt both: `sops hosts/metis/secrets.yaml && sops hosts/panoptes/secrets.yaml`
4. Add the `hooks` block to `/var/lib/metis/.config/openclaw/openclaw.json`
5. Rebuild Metis: `nixos-rebuild switch --flake .#metis` (opens port 18789)
6. Rebuild Panoptes: `nixos-rebuild switch --flake .#panoptes` (Alertmanager receiver + EnvironmentFile)
7. Restart ingress stack: `systemctl restart ingress` (Diun picks up webhook env vars)
8. Verify with test curls above

**Redundancy:** Both Alertmanager and Diun retain their existing Discord notifications.
The webhook is an additional delivery channel — if Metis is down, alerts still land in Discord.
