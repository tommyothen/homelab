# Runbook: Zeus Recovery

> **Scope:** Rebuild Zeus (Proxmox) from scratch and restore core VMs to service.
>
> **Estimated time:** 2-6 hours depending on VM reinstall and storage validation
>
> **Last reviewed:** 2026-03-05

---

## Prerequisites

- Proxmox ISO available offline and/or in cloud storage
- Out-of-band access path (Asclepius / PiKVM)
- VM configuration records (`qm config`) captured before failure
- Disk mapping notes for Mnemosyne passthrough

Known Zeus hardware snapshot (update as needed):

- CPU: `Intel i7 6700K`
- RAM: `32 GB DDR4`
- Boot disk: `1TB Samsung 970 EVO`
- NAS disks: `4x 4TB Samsung 870 QVO + 1x 18TB Seagate Exos X18`
- LAN NIC name: `<zeus-lan-interface>` (example: `eno1`)

---

## 1) Capture and maintain VM inventory (do this before incidents)

Run on Zeus as root:

```bash
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
  echo "=== VM ${vmid} ==="
  qm config "${vmid}"
  echo ""
done
```

Store output off-box (repo/cloud/external media).

Current expected VM inventory:

| VMID | Name | Role | RAM | Cores | OS Disk |
|---|---|---|---|---|---|
| 100 | mnemosyne | TrueNAS SCALE (NFS storage) | 16 GB | 4 | 32 GB virtio |
| 101 | dionysus | NixOS media VM | 8 GB | 4 | 40 GB virtio |
| 102 | panoptes | NixOS ops VM | 4 GB | 2 | 20 GB virtio |

---

## 2) Record passthrough mappings

Document exact devices used for Mnemosyne passthrough:

```bash
lspci | grep -i sata
ls /dev/disk/by-id/
```

Keep a mapping block in your notes, for example:

```text
/dev/disk/by-id/ata-<disk1> -> pool: media-hdd
/dev/disk/by-id/ata-<disk2> -> pool: apps-ssd
```

---

## 3) Reinstall Proxmox on Zeus

1. Boot from Proxmox ISO (use PiKVM if needed)
2. Install on Zeus boot disk only
3. Do not modify NAS disks during install
4. Reuse hostname `zeus`
5. Set static IP from `net.hosts.zeus` in `flake.nix` (`<zeus-lan-ip>`)
6. Set gateway to `<lan-gateway-ip>`

Post-install package setup:

```bash
rm /etc/apt/sources.list.d/pve-enterprise.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-sub.list
apt update && apt dist-upgrade -y
```

Stop-check:

- Proxmox UI reachable and host networking stable.

---

## 4) Restore or recreate VM disks

If VM OS disks were on Zeus local storage, choose one path:

### Option A (recommended): fresh NixOS install

1. Create VMs with matching resources
2. Boot NixOS ISO
3. Install host config from flake

Reference command pattern:

```bash
# Example pattern
# nixos-install --flake github:tommyothen/homelab#<host>
```

### Option B: restore from Proxmox backup

```bash
qmrestore /path/to/backup/<vmid>.zst <vmid>
```

---

## 5) Recreate VMs in dependency order

Recreate in VMID order (Mnemosyne first), using captured `qm config`.

Example creation pattern:

```bash
qm create 100 \
  --name mnemosyne \
  --memory 16384 \
  --cores 4 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --ide2 local:iso/TrueNAS-SCALE-*.iso,media=cdrom \
  --boot order=ide2

qm set 100 --scsi1 /dev/disk/by-id/ata-<YOUR-DISK-ID>
```

Stop-check:

- VM definitions exist for 100/101/102 and all expected passthrough mappings are present.

---

## 6) Boot Mnemosyne first and validate storage

1. Start VM 100
2. Confirm ZFS pools import
3. If needed, force import:

```bash
zpool import -f media-hdd
zpool import -f apps-ssd
```

4. Validate NFS exports and paths:
   - `/mnt/media-hdd/media`
   - `/mnt/apps-ssd/appdata`

Stop-check:

- NFS exports online and path names match what NixOS VMs expect.

---

## 7) Boot Dionysus and Panoptes

```bash
qm start 101
qm start 102
```

On each host, verify mounts and start stacks as needed:

```bash
mount | grep nfs
sudo systemctl start media-core media-vpn media-extras books personal paperless
sudo systemctl start ingress
```

Stop-check:

- NFS mounts are healthy and stack services start cleanly.

---

## 8) Validate service health

Quick Plex check:

```bash
curl -s http://dionysus:32400/web
```

Expected: HTML response.

If Metis is also down (not hosted on Zeus), recover separately:

```bash
# Metis state is local at /var/lib/metis
# Reinstall pattern:
# nixos-install --flake .#metis
```

---

## 9) Network reference

```text
Zeus (Proxmox):         <zeus-lan-ip>        (match `net.hosts.zeus` in `flake.nix`)
Mnemosyne (TrueNAS VM): <mnemosyne-lan-ip>
Dionysus (NixOS VM):    <dionysus-lan-ip>
Panoptes (NixOS VM):    <panoptes-lan-ip>
Cerberus (Pi 4B, DNS):  <cerberus-lan-ip>
Metis (Pi 4B, AI):      <metis-lan-ip>
```

Bridge: `vmbr0` on Zeus LAN interface.

---

## 10) Post-recovery checklist

- [ ] Plex reachable at `http://dionysus:32400/web`
- [ ] Grafana reachable at `https://grafana.0x21.uk`
- [ ] Prometheus targets healthy at `https://prometheus.0x21.uk/targets`
- [ ] Action Gateway health endpoint responds
- [ ] Gatus checks green at `https://status.0x21.uk`
- [ ] ZFS pools healthy in TrueNAS
- [ ] Tailscale connected on all hosts

---

## Troubleshooting quick commands

```bash
# Proxmox
qm list
for vmid in 100 101 102; do qm start "$vmid"; done

# TrueNAS storage
zpool status
zpool import -f media-hdd
zpool import -f apps-ssd

# NFS check on NixOS VMs
systemctl list-units --type=mount | grep nfs
```
