# Runbook: Provision a New NixOS VM on Proxmox

> **Scope:** Provision a fresh NixOS 25.11 VM on Proxmox VE, bootstrap SSH/Tailscale/sops tooling, then hand off to flake-managed configuration.
>
> **Estimated time:** ~15 minutes
>
> **Last tested:** 2026-03-05 on Proxmox VE 8.x and NixOS 25.11

---

## Prerequisites

- Proxmox VE host with a NixOS minimal ISO uploaded to `local` storage
- SSH public key for your admin user
- Assigned VM ID and hostname per your naming convention
- Internet access from the installer environment (to fetch bootstrap config from GitHub)

---

## 1) Create the VM in Proxmox

### General

| Setting | Value |
|---|---|
| VM ID | Per naming scheme |
| Name | Hostname (example: `athena`) |
| Start at boot | Off (enable after flake handoff) |

### OS

| Setting | Value |
|---|---|
| ISO image | `nixos-minimal-25.11-*.iso` |
| Storage | `local` |
| Type | Linux |
| Version | 6.x - 2.6 Kernel |

### System

| Setting | Value |
|---|---|
| Machine | `q35` |
| BIOS | `OVMF (UEFI)` |
| Add EFI Disk | Enabled |
| EFI Storage | VM storage (example: `local-lvm`) |
| Pre-Enroll keys | Disabled |
| SCSI Controller | VirtIO SCSI single |
| QEMU Agent | Enabled |

> `Pre-Enroll keys` is effectively the Secure Boot toggle in this workflow.
> If enabled, first boot can fail with `BdsDxe: Not Found` / `Access Denied`.

### Disks

| Setting | Value |
|---|---|
| Bus | SCSI (default; disk appears as `/dev/sda`) |
| Storage | VM storage |
| Size | 40 GiB (or as required) |
| Discard | Enable on SSD-backed storage |
| IO Thread | Enabled |

> If using VirtIO Block instead of SCSI, the disk is typically `/dev/vda`.

### CPU

| Setting | Value |
|---|---|
| Cores | 2+ (per workload) |
| Type | `host` |

### Memory

| Setting | Value |
|---|---|
| Memory | 8192 MiB (per workload) |

### Network

| Setting | Value |
|---|---|
| Bridge | `vmbr0` (or your LAN bridge) |
| Model | VirtIO (paravirtualized) |

---

## 2) Boot the installer

Start the VM and open console (noVNC or xterm.js).

Verify UEFI mode:

```bash
ls /sys/firmware/efi
# Must exist; if missing, review OVMF/BIOS settings.
```

---

## 3) Partition and format

```bash
DISK=/dev/sda  # /dev/sda for SCSI, /dev/vda for VirtIO Block

sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0     -t 2:8300 -c 2:"NixOS" "$DISK"

mkfs.fat -F 32 -n BOOT "${DISK}1"
mkfs.ext4 -L nixos "${DISK}2"
```

---

## 4) Mount filesystems

```bash
mount "${DISK}2" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot
```

---

## 5) Generate config and apply bootstrap

```bash
nixos-generate-config --root /mnt
```

Fetch bootstrap config from GitHub:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/tommyothen/homelab/main/bootstrap/standalone.nix \
  -o /mnt/etc/nixos/standalone.nix
```

Sanity check:

```bash
head -5 /mnt/etc/nixos/standalone.nix
```

---

## 6) Install NixOS

```bash
nixos-install --root /mnt -I nixos-config=/mnt/etc/nixos/standalone.nix
```

When prompted, set a root password for emergency console recovery.
You can disable/remove it later in flake-managed config.

> Warning about `/boot` being world-accessible is expected on FAT32 EFI partitions.

---

## 7) Verify before reboot

```bash
# 1) systemd-boot binaries
ls /mnt/boot/EFI/systemd/systemd-bootx64.efi
ls /mnt/boot/EFI/BOOT/BOOTX64.EFI

# 2) NixOS boot entries
ls /mnt/boot/loader/entries/

# 3) NVRAM entry
efibootmgr -v
# Expect entry like:
# Linux Boot Manager -> \EFI\systemd\systemd-bootx64.efi
```

---

## 8) Reboot and detach ISO

```bash
reboot
```

In Proxmox UI: **Hardware -> CD/DVD Drive -> Do not use any media**.

---

## 9) First login

Find the VM LAN IP (DHCP lease or console output), then:

```bash
ssh <admin-user>@<vm-lan-ip>
```

Accept and store the host key fingerprint.

---

## 10) Post-boot checklist

### Authenticate Tailscale

```bash
sudo tailscale up
```

Open the URL shown by `tailscale` to authorize the node.

### Get host age key

```bash
sops-host-age
# Outputs: age1...
```

Add it to `.sops.yaml` in the homelab repo:

```yaml
keys:
  - &new-host age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
creation_rules:
  - path_regex: hosts/new-host/.+
    key_groups:
      - age:
        - *new-host
```

### Validate baseline state

```bash
# SSH settings
sudo sshd -T | grep -E 'ciphers|macs|kexalgorithms|passwordauthentication|permitrootlogin'

# Tailscale state
tailscale status

# Flake availability
nix flake metadata nixpkgs
```

---

## 11) Hand off to flake config

1. Add host to `flake.nix`
2. Add host-specific NixOS module/config
3. Copy `hardware-configuration.nix` from VM into repo
4. Deploy with:

   ```bash
   nixos-rebuild switch --flake .#<hostname>
   ```

5. Remove `/etc/nixos/standalone.nix` once flake deployment is confirmed

---

## Troubleshooting

### `BdsDxe: Not Found` / `Access Denied` on boot

Secure Boot is enabled.
Disable it in OVMF setup (Esc at boot -> Device Manager -> Secure Boot Configuration)
or recreate VM with `Pre-Enroll keys` disabled.

### `nixos-install` fails on `services.openssh.settings.Ciphers`

NixOS 25.11 expects lists for OpenSSH settings:

```nix
# Wrong
Ciphers = "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com";

# Correct
Ciphers = [ "chacha20-poly1305@openssh.com" "aes256-gcm@openssh.com" ];
```

### SSH lockout after first boot

If bootstrap restricts SSH to `tailscale0`, you may lock yourself out before
Tailscale auth completes. Keep SSH open on initial bootstrap; tighten interface
and firewall rules in flake config later.

### Disk path mismatch (`/dev/sda` vs `/dev/vda`)

SCSI commonly appears as `sd*`; VirtIO Block as `vd*`.
Check with `lsblk` and update commands accordingly.

### No Linux Boot Manager in `efibootmgr -v`

Recreate EFI boot entry manually:

```bash
efibootmgr --create --disk /dev/sda --part 1 \
  --label "Linux Boot Manager" \
  --loader '\EFI\systemd\systemd-bootx64.efi'
```
