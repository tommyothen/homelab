# Homelab Infrastructure

Source of truth for a reproducible homelab. NixOS host configs, Docker Compose stacks, and the Action Gateway for safe AI-assisted operations.

**Core constraint:** Plex stays up. Everything else is secondary.

---

## Goals

- **Reproducible** — every service is defined in this repo and can be rebuilt from scratch in a single session
- **Declarative** — prefer native NixOS modules over Docker containers wherever practical; config lives in git, not click-through UIs
- **Stable** — pinned flake inputs, no bleeding-edge packages on servers
- **Secure** — SSH keys only, no admin UIs reachable from LAN or WAN; all admin access is Tailscale-only
- **Safe automation** — Metis starts read-only; any infrastructure action it requests requires human approval before anything runs

---

## Network

Residential eero network (`192.168.4.0/22`). LAN IPs and the gateway are defined once in `flake.nix` (`net.hosts`) and passed to every NixOS host via `specialArgs`.

> **DHCP reservations required.** Reserve these IPs in eero's DHCP settings. Without this, a reboot can cause an address conflict.

| Host | LAN IP | Role |
|------|--------|------|
| Cerberus (AdGuard / DNS) | `192.168.4.119` | NixOS Pi 4B |
| Metis | `192.168.4.248` | NixOS Pi 4B |
| Hestia (Home Assistant) | `192.168.5.180` | Home Assistant Yellow |
| Dionysus | `192.168.5.233` | NixOS VM (media) |
| Panoptes | `192.168.5.234` | NixOS VM (ops) |
| Mnemosyne (TrueNAS / NFS) | `192.168.5.228` | TrueNAS VM |
| Zeus (Proxmox) | `192.168.4.243` | Hypervisor |

**External OCI hosts** (ARM free tier) are defined under `net.external` in `flake.nix`. Two separate VMs — kept strictly isolated so a game-server compromise can't reach backup storage:

| Host | Role | Resources |
|------|------|-----------|
| Tartarus | Off-site backup target (restic over SSH) | 1 OCPU / 6 GB / 50 GB |
| Hephaestus | Game servers (Minecraft via Pterodactyl) | 3 OCPU / 18 GB / 150 GB |

Update the placeholder IPs in `flake.nix` → `net.external` after provisioning.

### Tailscale IPs

Every NixOS host runs Tailscale. Tailscale IPs live in `flake.nix` under `net.tailscale` and are used anywhere admin traffic must be restricted to the overlay (Prometheus scrape targets, Traefik backend routing).

**After first boot on each host, run `scripts/tailscale-ips.sh` to extract all IPs and print the exact `flake.nix` block to paste.** This covers all hosts including Tartarus and Hephaestus.

```bash
./scripts/tailscale-ips.sh
```

### Routing architecture

```
Client (LAN or Tailscale)
    │
    │  HTTPS request to *.0x21.uk
    ▼
AdGuard DNS on Cerberus
    │  Split DNS policy:
    │    home/plex/seerr.0x21.uk → Panoptes LAN IP
    │    all other *.0x21.uk     → Panoptes Tailscale IP
    ▼
Traefik on Panoptes (split entrypoints)
    │  Tailscale entrypoint: admin/control-plane routes
    │  LAN entrypoint: home, plex, seerr
    │  Wildcard cert via Cloudflare DNS-01 challenge
    │  Authentik forward auth on protected routes
    ▼
Backend service (Dionysus via Tailscale, Hestia via LAN, or localhost via br-panoptes bridge)
```

**Why guests can't access admin pages:** Cerberus sends admin hostnames to Panoptes's Tailscale IP, which is unreachable from non-Tailscale clients. Even though Traefik also listens on the LAN interface, only explicitly allowlisted routers (`home`, `plex`, `seerr`) are bound there; admin routers are bound to the Tailscale entrypoint only.

**Home-wide routes:** `home.0x21.uk` (Home Assistant), `plex.0x21.uk`, and `seerr.0x21.uk` are intentionally reachable on the LAN via Traefik.

---

## Machines

### Hestia — Home Assistant Yellow
Home automation. Exposed on `home.0x21.uk` via Traefik LAN/Tailscale ingress on Panoptes.

---

### Cerberus — Raspberry Pi 4B
**Role:** DNS + network gateway

- NixOS (aarch64), pinned via flake
- **AdGuard Home** — native `services.adguardhome` NixOS module (no Docker)
- Tailscale

**AdGuard DNS rewrites are fully declarative in `hosts/cerberus/default.nix`:**

```nix
services.adguardhome.settings.dns.rewrites = [
  { domain = "home.0x21.uk";  answer = net.hosts.panoptes; }      # LAN route
  { domain = "plex.0x21.uk";  answer = net.hosts.panoptes; }      # LAN route
  { domain = "seerr.0x21.uk"; answer = net.hosts.panoptes; }      # LAN route
  { domain = "*.0x21.uk";     answer = net.tailscale.panoptes; }  # admin routes
  { domain = "dionysus";  answer = net.hosts.dionysus; }
  # ... etc.
];
```

Split DNS policy keeps admin routes on Tailscale while allowing selected home routes on LAN.

**Ports open on Cerberus:**
| Port | Interface | Purpose |
|------|-----------|---------|
| 53 TCP/UDP | LAN | DNS for all clients (guests included) |
| 3000 TCP | `tailscale0` | AdGuard web UI |
| 9100 TCP | `tailscale0` | Prometheus node exporter |

**First-run:** After `nixos-rebuild switch`, the AdGuard web UI is at `http://<cerberus-tailscale-ip>:3000` from any Tailscale client. Set your admin password there. DNS rewrites are already in place from the Nix config — no manual click-through needed.

---

### Zeus — Mini PC
**Role:** Main hypervisor

- Proxmox VE (bare metal)
- All lab VMs live here; nothing runs on the Proxmox host itself
- Prometheus metrics scraped via `prometheus-pve-exporter` on Panoptes

See `runbooks/zeus-recovery.md` for the full rebuild procedure. **Fill in the VM config table there before you need it.**

---

### Mnemosyne — TrueNAS VM on Zeus
**Role:** Storage

- TrueNAS SCALE, physical disks passed through
- `media-hdd` pool — movies/TV at `/mnt/media-hdd/media`
- `apps-ssd` pool — all appdata, configs, databases at `/mnt/apps-ssd/appdata`
- NFS exports consumed by Dionysus, Panoptes, and Metis
- **Scrutiny** (TrueNAS native app) — HDD S.M.A.R.T monitoring with historical trends

The `apps-ssd/appdata` share stores persistent app data and non-secret runtime config. Secrets are managed via `sops-nix` and decrypted only into `/run/secrets` at activation.

**Backups:** See `runbooks/offsite-backup.md` for setting up encrypted restic backups to Tartarus. The `backup-check` Action Gateway action polls the TrueNAS API daily and alerts to Discord if snapshots are stale.

---

### Dionysus — Media VM on Zeus
**Role:** Media services + personal productivity

- NixOS (x86_64), Docker, Intel QSV hardware transcoding
- NFS mounts from Mnemosyne: `/data/media`, `/var/lib/appdata`
- Local SSD partition at `/data/downloads` for in-progress downloads

**All service ports are `tailscale0`-only** (except Plex on 32400). Traefik on Panoptes reaches them via the Tailscale overlay using `DIONYSUS_TAILSCALE_IP` as the backend address.

**Compose stacks:**

| Stack | Services |
|-------|----------|
| `stacks/dionysus/media-core` | Plex, Sonarr, Radarr, Prowlarr, Seerr, SABnzbd |
| `stacks/dionysus/media-vpn` | Gluetun + qBittorrent (VPN-tunnelled torrent fallback) |
| `stacks/dionysus/media-extras` | Seanime (anime UI), Tdarr (media transcoding) |
| `stacks/dionysus/books` | LazyLibrarian, Calibre-Web Automated, Shelfmark |
| `stacks/dionysus/personal` | Mealie, Actual Budget, Wallos, Stirling PDF, IT-Tools |
| `stacks/dionysus/paperless` | Paperless-ngx (PostgreSQL + Redis + web) |

**Books stack:** LazyLibrarian grabs books via Prowlarr indexers and drops them into an ingest folder. Calibre-Web Automated watches the ingest folder, imports and converts automatically, and serves an OPDS feed. Shelfmark is a self-hosted book search frontend. KOReader on a BOOX connects to the OPDS feed for 2-way progress sync.

**Download strategy:** Usenet via SABnzbd for common releases; qBittorrent-behind-Gluetun as fallback for niche/older content.

**Tdarr:** Runs an internal transcoding node using Intel Quick Sync (`/dev/dri`). Processes the media library to preferred codecs to reduce real-time Plex transcoding load.

**Paperless-ngx:** Document management with OCR. Consume directory at `${APPDATA_DIR}/paperless/consume` — drop PDFs/photos in there for automatic ingestion.

---

### Panoptes — Ops VM on Zeus
**Role:** Observability, ingress, SSO, and the Action Gateway

- NixOS (x86_64), Docker
- NFS mount from Mnemosyne for `/var/lib/appdata`

**Native NixOS services:**

| Service | Purpose |
|---------|---------|
| Prometheus | Scrapes all hosts on `tailscale0:9100` + Proxmox via pve-exporter + Speedtest Tracker |
| Grafana | Dashboards, provisioned datasources from Nix config |
| Alertmanager | Routes to OpenClaw webhook on Metis; investigates alerts automatically |
| Action Gateway | Safe execution surface for Metis-requested actions (parameterized, with reason/context) |
| Homelab MCP Server | Read-only observability tools for Metis via MCP (port 8090, Tailscale-only) |

**Compose stack (`stacks/panoptes/ingress`):**

| Service | Purpose |
|---------|---------|
| **Traefik** | HTTPS ingress, wildcard cert, Authentik forward auth |
| **Gatus** | Declarative uptime monitoring (config in git) |
| Homepage | Dashboard — widgets for every service |
| Homelab Hub | Inventory + topology map (JSON export/import backup) |
| Authentik | SSO / identity provider — forward auth for all `*.0x21.uk` apps |
| Notifiarr | Arr stack → Discord notifications |
| Diun | Docker image update notifier → Discord + OpenClaw webhook on Metis |
| Speedtest Tracker | ISP speed history; metrics at `/api/prometheus` scraped by Prometheus |
| Miniflux | Private RSS reader |
| **pve-exporter** | Prometheus exporter for Proxmox VE metrics |

#### Traefik

Static config at `stacks/panoptes/ingress/traefik/traefik.yml`. Dynamic routes in `stacks/panoptes/ingress/traefik/dynamic/`:

| File | Routes |
|------|--------|
| `dionysus.yml` | All Dionysus services — backends use `{{ env "DIONYSUS_TAILSCALE_IP" }}` |
| `cerberus.yml` | AdGuard web UI — backend uses `{{ env "CERBERUS_TAILSCALE_IP" }}` |
| `hestia.yml` | Home Assistant (`home.0x21.uk`) — backend uses `{{ env "HESTIA_LAN_IP" }}:8123` |
| `hephaestus.yml` | Pterodactyl Panel (`panel.0x21.uk`) — backend uses `{{ env "HEPHAESTUS_TAILSCALE_IP" }}:8080` |
| `asclepius.yml` | PiKVM (`kvm.0x21.uk`) — backend uses `{{ env "ASCLEPIUS_TAILSCALE_IP" }}` |
| `panoptes-native.yml` | Grafana, Prometheus — backends use `host-gateway` (Docker bridge) |
| `middleware.yml` | Authentik forwardAuth definition |

**Traefik → Grafana/Prometheus routing:** Both are NixOS-native services on the same host as the Traefik container. Traefik uses `host-gateway` (Docker's special hostname mapping to the host on the bridge). The Docker bridge is named `br-panoptes` via `driver_opts` in the compose network definition, which lets the NixOS firewall open those ports specifically to that bridge interface without exposing them anywhere else.

#### Gatus

Declarative uptime monitoring. The entire monitoring config lives at `stacks/panoptes/ingress/gatus/config.yaml` — checked into git, no UI state. All endpoints, intervals, and conditions are version-controlled. Monitors: Media (8 services), Books (2), Personal (2), Observability (2), Infrastructure (4), Backup (3 — Tartarus SSH, TrueNAS API, NFS port), Game Servers (2 — Hephaestus Panel, Minecraft public port).

#### Action Gateway

The controlled execution surface between Metis and the infrastructure. Metis can _request_ actions (with a reason and parameters); a human must _approve_ them before anything runs. Metis can poll action status after submission.

```
Metis (OpenClaw)
    │
    │  POST /action/<name>  {"reason": "...", "context": {"PARAM": "value"}}
    ▼
Action Gateway (FastAPI, tailscale0:8080)  ──►  SQLite audit log
    │
    │  Validates params against schema, creates pending record, posts to Discord bot
    ▼
Discord Bot (discord.py, WebSocket — no public endpoint needed)
    │
    │  Embed with reason, parameters, [Approve] [Deny] buttons → #mission-control
    ▼
Human clicks button
    │
    ▼
scripts/actions/<name>.sh  (runs as non-root action-gateway user, params as env vars)
    │
    │  stdout/stderr posted back to Discord
    ▼
Audit log updated (completed / failed / denied / expired)
    │
    ▼
Metis polls GET /action/{id} to check outcome
```

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/action/{name}` | Request an action with optional `reason` and `context` (validated against `actions.yaml` params schema) |
| `GET`  | `/action/{action_id}` | Get full status of a specific action by UUID |
| `GET`  | `/actions` | List allowlisted actions (with params schema if defined) |
| `GET`  | `/log` | Recent audit entries |
| `GET`  | `/health` | Liveness check |

**Registered actions (`services/action-gateway/actions.yaml`):**

| Action | Script | Purpose |
|--------|--------|---------|
| `health-check` | `health-check.sh` | Full HTTP + SSH service check |
| `daily-report` | `daily-report.sh` | Prometheus + disk + container + snapshot summary |
| `backup-check` | `backup-check.sh` | TrueNAS snapshot age check (alerts if stale) |
| `restart-plex` | `restart-plex.sh` | Restart Plex container on Dionysus |
| `restart-stack-{media,books,personal,paperless}` | wrapper → `restart-stack.sh` | Restart a compose stack |
| `restart-stack-ingress` | `restart-stack-ingress.sh` | Restart Panoptes ingress stack |
| `restart-container` | `restart-container.sh` | Restart a specific container on a target host (parameterized) |
| `update-containers` | `update-containers.sh` | Pull + recreate all Dionysus stacks |
| `rotate-logs` | `rotate-logs.sh` | Truncate oversized container logs |
| `digest-audit` | `digest-audit.sh` | Scan compose stacks for floating tags and enforce immutable pin checks |
| `refresh-digests` | `refresh-digests.sh` | Refresh pinned image digests from source tags and re-run checks |
| `rebuild-{cerberus,dionysus,panoptes,metis}` | wrapper → `rebuild-host.sh` | git pull + `nixos-rebuild switch` |
| `backup-now` | `backup-now.sh` | Ad-hoc restic backup to Tartarus |
| `dr-test` | `dr-test.sh` | DR readiness: Tartarus SSH + restic snapshot check |
| `proxmox-vm-status` | `proxmox-vm-status.sh` | List Proxmox VMs with status/CPU/memory |
| `tailscale-status` | `tailscale-status.sh` | Tailscale mesh node status |
| `cert-status` | `cert-status.sh` | Check ACME certificate expiry dates |
| `truenas-snapshot-status` | `truenas-snapshot-status.sh` | List recent TrueNAS snapshots |
| `sync-metis-repo` | `sync-metis-repo.sh` | Pull latest repo on Metis's local clone |

- **Allowlist** — only actions in `actions.yaml` can be queued; everything else is HTTP 400
- **Parameterized** — actions can define a `params` schema with required fields and regex validation
- **Approval** — only `@gateway-approver` role members can approve; expires after 15 min
- **Scripts** run as the `action-gateway` system user; target hosts have narrow `sudoers` rules
- **No public inbound port** — Discord bot uses a persistent WebSocket (gateway mode)

#### Homelab MCP Server

Read-only observability tools exposed via the [Model Context Protocol](https://modelcontextprotocol.io/) for Metis's OpenClaw agent. Runs on Panoptes as a systemd service (`mcp-homelab`) on port 8090 (Tailscale-only).

| Tool | Description | Backend |
|------|-------------|---------|
| `prometheus_query` | Run PromQL instant query | Prometheus API |
| `prometheus_query_range` | Run PromQL range query (trends) | Prometheus API |
| `prometheus_alerts` | List firing alerts | Prometheus API |
| `loki_query` | Search logs via LogQL | Loki API |
| `container_status` | List Docker containers on a host | SSH + `docker ps` |
| `nixos_generations` | Show recent NixOS generations | SSH + `nixos-rebuild list-generations` |
| `gatus_status` | Get endpoint uptime status | Gatus API |
| `tailscale_status` | Tailscale mesh node status | `tailscale status --json` |
| `disk_usage` | Per-host disk usage | PromQL wrapper |

---

### Metis — Raspberry Pi 4B
**Role:** AI co-DevOps engineer

- NixOS (aarch64), pinned via flake
- [OpenClaw](https://github.com/openclaw/openclaw) (Node.js ≥ 22, npm-installed on first boot)
- Discord is a native built-in channel — no separate bot code
- Credentials injected from `hosts/metis/secrets.yaml` via `sops-nix` (`/run/secrets`, local to Metis)
- **Observability:** queries Prometheus, Loki, container status, and Tailscale mesh via MCP tools on the Homelab MCP Server (Panoptes:8090)
- **Alert-driven investigation:** receives Alertmanager alerts and Diun image update notifications via OpenClaw webhooks (port 18789, Tailscale-only); automatically investigates and posts findings to Discord
- **Actions:** submits parameterized action requests (with reason) to the Panoptes Action Gateway over Tailscale; a human approves before anything executes
- **Infrastructure changes:** proposes changes via GitHub PRs using a repo-scoped deploy key and fine-grained PAT (cannot approve or merge its own PRs)
- **Proactive monitoring:** scheduled health sweeps, daily reports, digest audits, disk trend analysis, and flake lock checks
- **Local repo clone** at `/var/lib/metis/homelab` — cloned on first boot via systemd oneshot
- Never has direct root SSH access to production hosts

---

### Asclepius — PiKVM
Out-of-band recovery. Used when a host won't boot or SSH is unreachable.

---

### Tartarus — OCI ARM Free Tier
**Role:** Off-site encrypted backup target

- NixOS (aarch64), minimal footprint — no Docker, no extra services
- Receives encrypted restic snapshots from Mnemosyne over SSH/SFTP
- `backup-repo` system user with SSH key auth; shell access restricted to restic operations
- Repository at `/data/restic/mnemosyne/{apps-ssd,media-hdd}/`
- IP lives in `net.external.tartarus` in `flake.nix` — update the placeholder

See `runbooks/offsite-backup.md` for full setup.

---

### Hephaestus — OCI ARM Free Tier
**Role:** Game servers (Minecraft via Pterodactyl)

- NixOS (aarch64), Docker
- **Pterodactyl Wings** — NixOS systemd service managing game server Docker containers
- **Pterodactyl Panel** — Docker Compose at `stacks/hephaestus/pterodactyl/`; accessible via `panel.0x21.uk` through Traefik on Panoptes (Tailscale-only)
- Minecraft ports (25565–25574) open to the public internet; all admin access via Tailscale
- IP lives in `net.external.hephaestus` in `flake.nix` — update the placeholder

**Security note:** Intentionally isolated from Tartarus. Game servers (log4j etc.) have no network path to backup storage.

**First-run:** Deploy Wings config from the Panel → see `hosts/hephaestus/default.nix` for the first-run checklist.

---

## Repository Layout

```
.
├── flake.nix                          # Pins nixos-25.11; sops-nix input; net topology + all hosts
├── .sops.yaml                         # SOPS encryption config — fill in age keys after first boot
├── bootstrap/
│   ├── standalone.nix                 # Proxmox VM bootstrap config (minimal NixOS for first deploy)
│   ├── pi/                            # Raspberry Pi NixOS bootstrap (aarch64 image builder)
│   └── oci/                           # OCI ARM64 NixOS image builder
│       ├── flake.nix
│       └── configuration.nix
├── terraform/
│   └── oci/                           # Terraform IaC for OCI free-tier instances
├── hosts/
│   ├── cerberus/                      # AdGuard Home (native NixOS) + Tailscale
│   │   ├── hardware-configuration.nix # TEMPLATE — replace with nixos-generate-config output
│   │   └── secrets.yaml               # sops-encrypted per-host secrets
│   ├── dionysus/                      # Media VM — Docker Compose stacks
│   │   ├── hardware-configuration.nix
│   │   ├── secrets.yaml
│   │   └── services/
│   │       └── stacks.nix             # systemd services for Docker Compose stacks
│   ├── panoptes/
│   │   ├── hardware-configuration.nix
│   │   ├── secrets.yaml
│   │   └── services/
│   │       ├── action-gateway.nix     # systemd service for the Action Gateway
│   │       ├── mcp-homelab.nix        # systemd service for the Homelab MCP Server
│   │       └── stacks.nix             # systemd service for the ingress stack
│   ├── metis/                         # AI ops Pi (OpenClaw)
│   │   ├── hardware-configuration.nix
│   │   └── secrets.yaml
│   ├── tartarus/                      # OCI ARM — off-site backup target (minimal)
│   │   └── hardware-configuration.nix
│   └── hephaestus/                    # OCI ARM — game servers (Docker + Wings)
│       ├── hardware-configuration.nix
│       ├── secrets.yaml
│       └── services/
│           └── stacks.nix             # systemd service for the Pterodactyl stack
├── modules/                           # Shared NixOS modules (all hosts import these)
│   ├── ssh-hardening.nix
│   ├── tailscale.nix                  # services.tailscale; per-interface firewall rules
│   ├── firewall-baseline.nix          # nftables; SSH open; everything else per-host
│   └── sops.nix                       # sops-nix: age key derivation from SSH host key
├── stacks/
│   ├── dionysus/
│   │   ├── media-core/                # Plex, Sonarr, Radarr, Prowlarr, Seerr, SABnzbd
│   │   ├── media-vpn/                 # Gluetun + qBittorrent
│   │   ├── media-extras/              # Seanime, Tdarr
│   │   ├── books/                     # LazyLibrarian, Calibre-Web Automated, Shelfmark
│   │   ├── personal/                  # Mealie, Actual Budget, Wallos, Stirling PDF, IT-Tools
│   │   └── paperless/                 # Paperless-ngx + PostgreSQL + Redis
│   ├── panoptes/
│   │   └── ingress/                   # Traefik, Gatus, Homepage, Homelab Hub, Authentik, pve-exporter, ...
│   │       ├── traefik/
│   │       │   ├── traefik.yml        # Static config (entrypoints, cert resolver, providers)
│   │       │   └── dynamic/           # File provider routes (one file per backend host)
│   │       ├── gatus/
│   │       │   └── config.yaml        # Declarative endpoint monitoring — checked into git
│   │       └── homepage/              # Homepage config (services, widgets, settings)
│   └── hephaestus/
│       ├── pterodactyl/               # Panel + MariaDB + Redis Docker Compose stack
│       └── infrared/                  # Minecraft reverse proxy (Infrared)
├── packages/
│   └── openclaw/                      # Vendored OpenClaw Nix derivation (buildNpmPackage)
├── services/
│   ├── action-gateway/                # FastAPI + discord.py Action Gateway
│   │   ├── main.py                    # API + param validation + status endpoint
│   │   ├── bot.py                     # Discord approval flow (reason/context in embeds)
│   │   ├── db.py                      # SQLite audit log (with reason/context/get_by_id)
│   │   ├── executor.py                # Script runner (with env_overrides)
│   │   └── actions.yaml               # Allowlisted actions (25 actions, with params schema)
│   └── metis/
│       ├── mcp-homelab/               # Homelab MCP Server (read-only observability tools)
│       │   ├── server.py              # 9 MCP tools (Prometheus, Loki, containers, etc.)
│       │   └── requirements.txt
│       └── OPENCLAW-CONFIG.md         # MCP server + system prompt + cron config guide
├── scripts/
│   ├── tailscale-ips.sh               # Extract Tailscale IPs → flake.nix update block
│   ├── security/
│   │   └── compose_digest_manager.py  # Scan/pin/refresh compose image digests
│   └── actions/                       # Scripts the Action Gateway may execute (25 actions)
│       ├── health-check.sh
│       ├── daily-report.sh
│       ├── backup-check.sh
│       ├── restart-plex.sh
│       ├── restart-stack.sh           # Core stack restart logic
│       ├── restart-stack-{media,books,personal,paperless}.sh
│       ├── restart-stack-ingress.sh   # Panoptes ingress stack
│       ├── restart-container.sh       # Parameterized: any container on any allowed host
│       ├── update-containers.sh
│       ├── rotate-logs.sh
│       ├── digest-audit.sh
│       ├── refresh-digests.sh
│       ├── rebuild-host.sh            # Core rebuild logic (called via wrapper scripts)
│       ├── rebuild-{cerberus,dionysus,panoptes,metis}.sh
│       ├── backup-now.sh
│       ├── dr-test.sh
│       ├── proxmox-vm-status.sh       # PVE API → VM status/CPU/memory
│       ├── tailscale-status.sh        # Mesh node status
│       ├── cert-status.sh             # ACME cert expiry check
│       ├── truenas-snapshot-status.sh  # ZFS snapshot listing
│       └── sync-metis-repo.sh         # Pull latest repo on Metis
└── runbooks/
    ├── zeus-recovery.md               # Full Proxmox + VM rebuild procedure
    ├── offsite-backup.md              # restic backup to Oracle — setup + restore guide
    ├── fresh-start-local-first.md     # Full greenfield rebuild from scratch
    ├── proxmox-nixos-vm-bootstrap.md  # New NixOS VM on Proxmox
    └── oci-nixos-deploy.md            # OCI ARM64 instance provisioning
```

---

## Secrets Policy

This repo is **sops-nix only** for secrets. There is no plaintext `.env` secret fallback path.

- Secrets live in `hosts/<host>/secrets.yaml` as SOPS-encrypted ciphertext and are safe to commit
- At deploy time, `sops-nix` decrypts to `/run/secrets` and systemd units consume those files via `EnvironmentFile`
- The host decryption identity is derived from `/etc/ssh/ssh_host_ed25519_key` (`sops.age.sshKeyPaths`)
- Plaintext secret files (for example real API keys in `.env`) are out of policy

Bootstrap steps:
1. Boot each host and run: `nix shell nixpkgs#ssh-to-age -c ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`
2. Paste the output into `.sops.yaml` under the host key entry
3. Encrypt host secrets: `nix run nixpkgs#sops -- hosts/<host>/secrets.yaml`
4. Rebuild that host so secrets materialize in `/run/secrets`

If `nix-command` and `flakes` are not enabled yet on a fresh host, run:

```bash
nix --extra-experimental-features "nix-command flakes" shell nixpkgs#ssh-to-age -c ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

Routing/bind IP values are injected from `flake.nix` into systemd-managed stack units on Panoptes and Hephaestus.

### Immutable image pinning workflow

All compose images should be pinned to immutable digests (`@sha256:...`) with
`# pinned-from: <image:tag>` metadata for refresh automation.

Use the local manager script:

```bash
python3 scripts/security/compose_digest_manager.py scan --root .
python3 scripts/security/compose_digest_manager.py check --root .
python3 scripts/security/compose_digest_manager.py pin --root . --write
python3 scripts/security/compose_digest_manager.py refresh --root . --write
```

OpenClaw can call this through the Action Gateway actions:

- `digest-audit` (read-only scan + enforce check)
- `refresh-digests` (update pins in-place + re-check)

---

## Security Baseline

- **SSH keys only** — password auth disabled (`modules/ssh-hardening.nix`)
- **All admin UIs are Tailscale-only**
  - Traefik uses split entrypoints: admin routers bind to Tailscale entrypoints only
  - AdGuard DNS uses split policy: `home`/`plex`/`seerr` resolve to Panoptes LAN IP; all other `*.0x21.uk` resolve to Panoptes Tailscale IP
  - All Dionysus admin ports remain `tailscale0`-only; only Plex is intentionally exposed on LAN
  - AdGuard web UI (3000) is `tailscale0`-only on Cerberus
- **Traefik wildcard cert** — `*.0x21.uk` via Cloudflare DNS-01 challenge; `CF_DNS_API_TOKEN` injected from `hosts/panoptes/secrets.yaml` via `sops-nix`
- **Authentik SSO** — all admin routes protected by forward auth (Plex, Seerr, Home Assistant, and Authentik itself use their own auth)
- **nftables on every host** — enabled via `modules/firewall-baseline.nix`; per-interface rules in each host config
- **Action Gateway** — binds `tailscale0:8080` only; invisible on LAN and WAN; Discord approval gate prevents autonomous execution
- **Homelab MCP Server** — binds `tailscale0:8090` only; read-only tools, no mutations; hardened systemd service
- **Metis git access** — deploy key scoped to a single repo; GH_TOKEN has `contents:write` + `pull_requests:write` only (no approve); branch protection requires human approval to merge

---

## Bring-up Order

Optimised to restore Plex first, then layer in everything else.

### Bootstrap note (fresh NixOS installs)

When a host is newly installed, your repo may be local-only (no remote), and `git`
may not yet be in the active environment. Recommended bootstrap flow:

1. Sync the repo from your laptop with `rsync` over SSH.
2. Use a `path:` flake URI for the first rebuild.

Example laptop -> Cerberus sync:

```bash
rsync -av --delete --no-owner --no-group ~/Programming/homelab/ root@<cerberus-lan-ip>:/root/homelab/
```

Then rebuild on Cerberus:

```bash
sudo nixos-rebuild switch --flake "path:/root/homelab#cerberus"
```

### 0. Update Tailscale IPs first

After each host joins Tailscale, run on any node that has `tailscale` installed:

```bash
./scripts/tailscale-ips.sh
# Prints the exact flake.nix tailscale block to paste
```

### 1. Cerberus — DNS first, everything depends on it

```bash
nixos-rebuild switch --flake "path:/root/homelab#cerberus"
sudo tailscale up
```

Access the AdGuard setup at `http://<cerberus-tailscale-ip>:3000` from any Tailscale client to set your admin password. DNS rewrites are already configured from Nix — no further AdGuard setup needed.

### 2. Zeus — Proxmox bare-metal install; verify storage controllers

See `runbooks/zeus-recovery.md` for the full procedure.

### 3. Mnemosyne — import pools, bring NFS exports online before Dionysus starts

### 4. Dionysus — media services

```bash
nixos-rebuild switch --flake .#dionysus
sudo tailscale up
# → run tailscale-ips.sh to update flake.nix
```

Start all Dionysus stacks in one command:
```bash
sudo systemctl start media-core media-vpn media-extras books personal paperless
```

Or start a single stack:
```bash
sudo systemctl start media-core
```

Confirm Plex streams before continuing.

### 5. Panoptes — ingress + observability

```bash
nixos-rebuild switch --flake .#panoptes
# → this brings up Prometheus, Grafana, Alertmanager natively

sudo tailscale up
# → run tailscale-ips.sh and update flake.nix
# → then rebuild panoptes so split-entrypoint binds use the real IPs

nixos-rebuild switch --flake .#panoptes

# Start the ingress stack (Traefik, Gatus, Homepage, Homelab Hub, Authentik, pve-exporter, ...):
sudo systemctl start ingress
```

**After Traefik is up:** verify the wildcard cert issued correctly:
```bash
echo | openssl s_client -connect <panoptes-tailscale-ip>:443 \
  -servername grafana.0x21.uk 2>/dev/null | openssl x509 -noout -subject
# Should show: subject=CN=*.0x21.uk
```

**Authentik first-run:** `https://auth.0x21.uk/if/flow/initial-setup/`

**Action Gateway last** (after `hosts/panoptes/secrets.yaml` is encrypted with SOPS and deployed):
```bash
systemctl start action-gateway
```

### 6. Metis

```bash
# Place credentials in hosts/metis/secrets.yaml (OpenClaw secrets, deploy key, GH token),
# encrypt with SOPS, then rebuild.

nixos-rebuild switch --flake .#metis
sudo tailscale up

# The metis-repo-clone oneshot clones the homelab repo on first boot.
# One-time onboarding:
sudo -u metis openclaw onboard

# Configure MCP servers in /var/lib/metis/.config/openclaw/openclaw.json
# See services/metis/OPENCLAW-CONFIG.md for the full config.

systemctl start openclaw
```

---

## Filling in Tailscale IPs

Use `scripts/tailscale-ips.sh` — it reads `tailscale status --json` and prints the exact text to paste.

```bash
./scripts/tailscale-ips.sh          # prints flake.nix tailscale block
```

One place needs updating:

| Location | What to fill in |
|----------|----------------|
| `flake.nix` → `net.tailscale.*` | Used by NixOS configs (Prometheus scrape targets, AdGuard DNS rewrites, firewall comments) |

Traefik/Gatus/Pterodactyl receive these values through NixOS systemd unit
environment in `hosts/panoptes/services/stacks.nix` and
`hosts/hephaestus/services/stacks.nix`.

After updating `flake.nix`, rebuild the affected hosts.

---

## Adding a New Service

**On Dionysus (Docker Compose):**
1. Add the service to the appropriate compose stack
2. Add its port to `hosts/dionysus/default.nix` → `interfaces.tailscale0.allowedTCPPorts`
3. Add a router + service entry to `stacks/panoptes/ingress/traefik/dynamic/dionysus.yml` using `{{ env "DIONYSUS_TAILSCALE_IP" }}:PORT`
4. Add an endpoint to `stacks/panoptes/ingress/gatus/config.yaml`
5. Add an entry to `stacks/panoptes/ingress/homepage/services.yaml`

**On Panoptes (Docker Compose, same host as Traefik):**
1. Add to `stacks/panoptes/ingress/docker-compose.yml` with Traefik labels (Docker provider picks these up automatically)
2. Add a Gatus endpoint using the container name as hostname (same Docker network)
3. No firewall changes needed — containers on `br-panoptes` are already reachable by Traefik

**Native NixOS service (any host):**
1. Add `services.<name>` block to the host's `default.nix`
2. Open required ports on the appropriate firewall interface (`tailscale0` for admin, LAN only if genuinely needed by non-Tailscale clients)
3. Add routing in the appropriate Traefik dynamic config file

---

## Runbooks

| Runbook | When to use |
|---------|-------------|
| `runbooks/zeus-recovery.md` | Zeus hardware failure — full Proxmox + VM rebuild procedure |
| `runbooks/offsite-backup.md` | First-time setup of encrypted restic backups from Mnemosyne to Tartarus |
| `runbooks/fresh-start-local-first.md` | Full greenfield rebuild from scratch |
| `runbooks/proxmox-nixos-vm-bootstrap.md` | New NixOS VM on Proxmox |
| `runbooks/oci-nixos-deploy.md` | OCI ARM64 instance provisioning |
| `runbooks/pi-bootstrap.md` | Raspberry Pi NixOS bootstrap procedure |
