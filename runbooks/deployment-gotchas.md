# Runbook: Deployment Gotchas

> **Scope:** Known issues and fixes encountered during NixOS deployments.
>
> **Last reviewed:** 2026-03-12

---

## Compose stacks: "no configuration file provided"

Docker Compose stacks reference `/opt/homelab/stacks/<host>/` on each host.
After the first NixOS deploy, clone the repo so the compose files are available:

```bash
sudo git clone https://github.com/tommyothen/homelab.git /opt/homelab
```

Affected hosts: **Dionysus**, **Panoptes**.

After cloning, restart the failed stacks:

```bash
sudo systemctl restart media-core media-vpn media-extras books personal paperless  # Dionysus
sudo systemctl restart ingress                                                      # Panoptes
```

---

## NFS mounts: "mkdir permission denied" in Docker

**Symptom:** Docker Compose fails with `error while creating mount source path: mkdir /var/lib/appdata/<service>: permission denied`.

**Cause:** TrueNAS NFS exports default to `root_squash`, which maps root to `nobody`. Docker (running as root) can't create subdirectories on the NFS share.

**Fix:** In TrueNAS SCALE, go to **Sharing > NFS**, edit the export, and set:
- **Maproot User:** `root`
- **Maproot Group:** `root`

Apply to both `apps-ssd/appdata` and `media-hdd/media` exports.

---

## AdGuard Home: DNS rewrites not applied

**Symptom:** Rewrites defined in NixOS config don't appear in AdGuard or show as `enabled: false`.

**Cause (1):** AdGuard schema v32+ moved `rewrites` from the `dns` section to the `filtering` section. The NixOS `settings.dns.rewrites` path is ignored.

**Fix:** Define rewrites under `settings.filtering.rewrites` instead of `settings.dns.rewrites`.

**Cause (2):** Newer AdGuard versions added a per-rewrite `enabled` field that defaults to `false`.

**Fix:** Add `enabled = true` to each rewrite entry:

```nix
filtering.rewrites = [
  { domain = "*.example.com"; answer = "10.0.0.1"; enabled = true; }
];
```

---

## Promtail: pipeline stage parse error

**Symptom:** `pipeline stage must contain only one key`.

**Cause:** Each pipeline stage in the Promtail config must be a single-key map. Putting `regex` and `source` as separate keys in one map fails.

**Wrong:**
```nix
{
  regex.expression = "...";
  source = "filename";
}
```

**Right:**
```nix
{
  regex = {
    expression = "...";
    source = "filename";
  };
}
```

---

## Promtail: NAMESPACE error (status 226)

**Symptom:** `Failed at step NAMESPACE spawning ... No such file or directory`.

**Cause:** `/var/lib/promtail` doesn't exist and systemd's `PrivateTmp`/mount namespace setup fails before it can be created.

**Fix (Panoptes):** Already handled in `default.nix`:
```nix
systemd.services.promtail.serviceConfig.PrivateTmp = lib.mkForce false;
```

**Fix (Dionysus):** Create the directory manually on first deploy:
```bash
sudo mkdir -p /var/lib/promtail
```

---

## Traefik: ACME email parse error

**Symptom:** `unable to parse email address` when requesting Let's Encrypt certs.

**Cause:** Go template env var syntax in `traefik.yml` (static config) uses escaped double quotes (`\"`) inside YAML double quotes, which produces literal backslashes.

**Fix:** Use YAML single quotes around the Go template expression:

```yaml
email: '{{ env "ACME_EMAIL" }}'
```

Not:
```yaml
email: "{{ env \"ACME_EMAIL\" }}"
```

---

## Traefik: dynamic config template parse error

**Symptom:** `unexpected "\\\\" in operand` for a dynamic config file.

**Cause:** Same YAML escaping issue as above in dynamic config files.

**Fix:** Use single quotes:

```yaml
- url: 'http://{{ env "HEPHAESTUS_TAILSCALE_IP" }}:8080'
```

---

## Gluetun: "interface address is not set"

**Symptom:** Gluetun exits immediately with `Wireguard settings: interface address is not set`.

**Cause:** Newer Gluetun versions require `WIREGUARD_ADDRESSES` in addition to `WIREGUARD_PRIVATE_KEY`. This is the WireGuard interface address from your VPN provider config (e.g., `10.64.x.x/32`).

**Fix:** Add `WIREGUARD_ADDRESSES` to both the sops secret and the compose file environment section.

---

## Action Gateway: "unable to open database file"

**Symptom:** uvicorn exits with `sqlite3.OperationalError: unable to open database file`.

**Cause:** `DB_PATH` defaults to `audit.db` relative to `WorkingDirectory` (`/opt/homelab/services/action-gateway/`), which is read-only under `ProtectSystem=strict`.

**Fix:** Set `DB_PATH` to the writable data directory in the systemd service:

```nix
Environment = [ "DB_PATH=${dataDir}/audit.db" ];
```

---

## Gatus: "out of memory" on SQLite open

**Symptom:** Gatus crashes with `unable to open database file: out of memory (14)`.

**Cause:** No persistent volume mounted for the SQLite database at `/data/`.

**Fix:** Add a named volume in the compose file:

```yaml
volumes:
  - ./gatus/config.yaml:/config/config.yaml:ro
  - gatus-data:/data
```

And declare `gatus-data:` in the top-level `volumes:` section.

---

## SSH host key not in known_hosts

**Symptom:** `nix-copy-closure` fails with `Host key verification failed` when deploying from WSL.

**Cause:** First time connecting to the host's Tailscale IP — key not yet trusted.

**Fix:** Accept the key before deploying:

```bash
ssh -o StrictHostKeyChecking=accept-new tommy@<tailscale-ip> "echo connected"
```

---

## Metis repo clone: "cannot run ssh"

**Symptom:** `metis-repo-clone` service fails with `error: cannot run ssh: No such file or directory`.

**Cause:** The `GIT_SSH_COMMAND` uses bare `ssh` but openssh isn't in the service's PATH.

**Fix:** Use the full Nix store path:

```nix
"GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=accept-new -i /var/lib/metis/.ssh/id_ed25519"
```
