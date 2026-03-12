# Runbook: Fresh Start (Local First, OCI Second)

> **Scope:** Rebuild the homelab from scratch with local infrastructure first, then OCI hosts.
>
> **Estimated time:** Multi-phase (typically 1-2 days depending on hardware and data steps)
>
> **Last reviewed:** 2026-03-05

---

## Prerequisites and assumptions

- This is an intentional full rebuild.
- NAS disks stay disconnected until storage setup steps.
- Local services must be stable before OCI bring-up.
- Secrets are managed with `sops-nix` (`hosts/<host>/secrets.yaml`), not plaintext `.env` files.

---

## 0) Bootstrap any fresh NixOS host

Bootstrap method depends on the host type:

**Raspberry Pi (Cerberus, Metis):** Build and flash a pre-configured SD image.
See `runbooks/pi-bootstrap.md` for the full procedure.

```bash
cd ~/Programming/homelab/bootstrap/pi
nix build .#packages.aarch64-linux.<hostname> --out-link result-<hostname>
# Flash result-<hostname>/sd-image/*.img.zst via Raspberry Pi Imager
```

**OCI ARM instances (Tartarus, Hephaestus):** Deploy via Terraform from an existing image.
See `runbooks/oci-nixos-deploy.md` for the full procedure.

**Proxmox VMs (Dionysus, Panoptes):** Install from NixOS ISO.
See `runbooks/proxmox-nixos-vm-bootstrap.md` for the full procedure.

After first boot on any host:

```bash
sudo tailscale up
sops-host-age   # prints age1... key — add to .sops.yaml
```

Then deploy the flake config from WSL:

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ~/Programming/homelab#<hostname> \
  --target-host tommy@<tailscale-ip> \
  --build-host tommy@<tailscale-ip> \
  --sudo
```

---

## 1) Machine order (do not reorder)

Build in this exact sequence:

1. Cerberus (DNS + Tailscale gate)
2. Zeus (Proxmox hypervisor)
3. Mnemosyne (TrueNAS + NFS)
4. Dionysus (media/apps VM)
5. Panoptes (ingress/observability/action gateway VM)
6. Metis (AI ops node)
7. Tartarus (OCI backup target)
8. Hephaestus (OCI game host)

Do not continue to the next machine until the stop-check for the current phase passes.

---

## 2) Phase 0 - Pre-flight

Complete before touching hosts:

- [ ] Repo is current locally
- [ ] If no remote is available, plan host sync with `rsync` over SSH
- [ ] `flake.nix` LAN addresses and gateway match reality
- [ ] Install media and access paths are ready (Pi images, Proxmox ISO, NixOS ISO, TrueNAS ISO)
- [ ] `.sops.yaml` has valid keys for hosts being deployed now
- [ ] `hosts/<host>/secrets.yaml` values are populated and SOPS-encrypted
- [ ] Old NAS drives are disconnected until storage phase

Verification:

```bash
grep -n "age1REPLACE" .sops.yaml || true
```

Stop-check:

- Proceed only when no placeholder keys remain for target hosts.

---

## 3) Phase 1 - Local foundation

### 3.1 Cerberus first

Why: DNS is foundational for local name resolution and wildcard behavior.

Flash the Pi SD image (see `runbooks/pi-bootstrap.md`), boot, authenticate Tailscale, then deploy:

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ~/Programming/homelab#cerberus \
  --target-host tommy@<tailscale-ip> \
  --build-host tommy@<tailscale-ip> \
  --sudo
```

Verify:

- AdGuard UI reachable from Tailscale client: `http://<cerberus-tailscale-ip>:3000`
- DNS resolution works for LAN clients
- `eth0` exists and has expected static IP

If `eth0` is missing:

1. Identify the real NIC with `ip -br link`
2. Update `hosts/cerberus/default.nix` (`networking.interfaces.<name>`)
3. Rebuild before continuing

Stop-check:

- Cerberus DNS must be stable before moving on.

### 3.2 Zeus second (Proxmox)

Why: all local VMs depend on Zeus.

High-level actions:

1. Install Proxmox on Zeus boot disk only
2. Keep NAS disks disconnected during install
3. Recreate VM shells in order: `mnemosyne` (100), `dionysus` (101), `panoptes` (102)

Detailed reference: `runbooks/zeus-recovery.md`

Stop-check:

- Proxmox reachable and VM definitions exist.

### 3.3 Mnemosyne third (TrueNAS)

Why: Dionysus and Panoptes require NFS mounts.

High-level actions:

1. Attach intended storage disks
2. Create/import pools for fresh start
3. Create/verify NFS exports:
   - `/mnt/media-hdd/media`
   - `/mnt/apps-ssd/appdata`

Stop-check:

- NFS exports are online and reachable from VM network.

### 3.4 Dionysus fourth

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ~/Programming/homelab#dionysus \
  --target-host tommy@<tailscale-ip> \
  --build-host tommy@<tailscale-ip> \
  --sudo
sudo systemctl start media-core media-vpn media-extras books personal paperless
```

Verify:

- NFS mounts present at `/data/media` and `/var/lib/appdata`
- Core media services active
- Plex reachable on LAN: `http://dionysus:32400/web`

Stop-check:

- Plex must be healthy before continuing.

### 3.5 Panoptes fifth

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ~/Programming/homelab#panoptes \
  --target-host tommy@<tailscale-ip> \
  --build-host tommy@<tailscale-ip> \
  --sudo
sudo systemctl start ingress
sudo systemctl start action-gateway
```

Verify:

- Traefik reachable over Tailscale
- Grafana/Prometheus routes load
- Action Gateway health endpoint responds

Stop-check:

- Ingress and observability must be usable.

### 3.6 Metis sixth

Flash the Pi SD image (see `runbooks/pi-bootstrap.md`), boot, authenticate Tailscale, then deploy:

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ~/Programming/homelab#metis \
  --target-host tommy@<tailscale-ip> \
  --build-host tommy@<tailscale-ip> \
  --sudo
sudo -u metis openclaw onboard
sudo systemctl start openclaw
```

Verify:

- Metis service active
- Metis can read observability context and request (not auto-run) actions
- `eth0` exists and has expected static IP

If `eth0` is missing:

1. Identify the real NIC with `ip -br link`
2. Update `hosts/metis/default.nix` (`networking.interfaces.<name>`)
3. Rebuild before continuing

Stop-check:

- Human approval flow via Action Gateway is functioning.

---

## 4) Phase 2 - Tailscale IP reconciliation

Run after each host joins Tailscale, and again after local phase completion.

```bash
./scripts/tailscale-ips.sh
```

Apply output to:

- `flake.nix` (`net.tailscale.*`)

Then:

- Rebuild all affected NixOS hosts
- Restart compose-backed services consuming updated `net.tailscale.*`
  - Panoptes: `sudo systemctl restart ingress`
  - Hephaestus (OCI phase): `sudo systemctl restart pterodactyl`

Stop-check:

- Current Tailscale IPs are reflected in config for all local hosts.

---

## 5) Phase 3 - OCI bring-up (after local stability)

### 5.1 Tartarus seventh

Why first in OCI: backup target should exist before additional external workloads.
Deploy via Terraform (see `runbooks/oci-nixos-deploy.md`), then:

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ~/Programming/homelab#tartarus \
  --target-host tommy@<tailscale-ip> \
  --build-host tommy@<tailscale-ip> \
  --sudo
```

Then complete `runbooks/offsite-backup.md`.

Stop-check:

- SSH reachable, restic repository initialized, snapshot listing works.

### 5.2 Hephaestus eighth

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ~/Programming/homelab#hephaestus \
  --target-host tommy@<tailscale-ip> \
  --build-host tommy@<tailscale-ip> \
  --sudo
sudo systemctl start pterodactyl
sudo systemctl start pterodactyl-wings
```

Verify:

- `panel.0x21.uk` reachable via Panoptes/Traefik over Tailscale
- Game ports and Wings exposure match intended policy

Stop-check:

- Panel and Wings healthy with no unintended access paths.

---

## 6) Final validation

- [ ] DNS split policy behaves as designed
- [ ] `home.0x21.uk`, `plex.0x21.uk`, `seerr.0x21.uk` reachable from LAN clients
- [ ] Admin UIs reachable only over Tailscale
- [ ] Secrets are sourced from SOPS and decrypted under `/run/secrets`
- [ ] Plex playback works
- [ ] Prometheus, Grafana, and Alertmanager are healthy
- [ ] Action Gateway approval flow works end-to-end
- [ ] Tartarus backup path verified (snapshot list + restore test)

---

## Rollback rules

- If any stop-check fails, do not proceed.
- Resolve failures at the current layer first (network/DNS -> storage -> app/ingress -> automation).
- Keep local foundation stable before touching OCI.
