# Runbook: Bootstrap Raspberry Pi Hosts (Cerberus + Metis)

> **Scope:** Build a NixOS SD card image for a Pi 4B, flash it, and hand off to flake config.
>
> **Applies to:** Cerberus (Pi-hole/AdGuard + Tailscale), Metis (AI ops node)
>
> **Last tested:** 2026-03-08 on NixOS 25.11, WSL2 with Determinate Nix

---

## Prerequisites

- WSL2 with Determinate Nix installed
- QEMU binfmt enabled for aarch64 cross-compilation (already set up for OCI work):
  ```bash
  sudo systemctl restart systemd-binfmt
  # Verify:
  cat /proc/sys/fs/binfmt_misc/qemu-aarch64   # should show "enabled"
  ```
- SD card reader + card (32 GB+ recommended)
- Raspberry Pi Imager installed on your machine

---

## 1) Build the SD image

```bash
cd ~/Programming/homelab/bootstrap/pi

# Build for the specific host (hostname is baked into the image)
nix build .#packages.aarch64-linux.cerberus --out-link result-cerberus
# or
nix build .#packages.aarch64-linux.metis --out-link result-metis
```

Output: `result-<host>/sd-image/nixos-sd-image-*.img.zst`

> Cross-compilation via QEMU is slow. Most packages come from the binary cache;
> expect ~10-20 minutes for the image assembly step.

---

## 2) Flash the image

Open **Raspberry Pi Imager**:

1. Choose OS → **Use custom image** → select the `.img.zst` file
2. Choose Storage → select your SD card
3. Click **Next** — do **not** apply any extra customisation (hostname/SSH/user are already baked in)
4. Flash and wait

---

## 3) First boot

Insert the SD card and power on. Wait ~30 seconds for boot to complete, then SSH in using the LAN IP (check your router's DHCP leases):

```bash
ssh tommy@<dhcp-ip>
```

The image uses DHCP on first boot. Static IP is set in the full flake config.

---

## 4) Post-boot checklist

### Authenticate Tailscale

```bash
sudo tailscale up
```

Open the URL shown to authorize the node in your Tailscale admin console.

### Get host age key

```bash
sops-host-age
# Outputs: age1...
```

Add to `.sops.yaml` in the homelab repo:

```yaml
keys:
  - &cerberus  age1...   # from sops-host-age on Cerberus
  - &metis     age1...   # from sops-host-age on Metis
```

### Update flake.nix Tailscale IP

```bash
tailscale ip -4
```

Update `net.tailscale.<host>` in `flake.nix`.

---

## 5) Hand off to flake config

Deploy from your WSL machine (builds on the Pi itself to avoid cross-compilation):

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ~/Programming/homelab#cerberus \
  --target-host tommy@<tailscale-ip> \
  --build-host tommy@<tailscale-ip> \
  --sudo
```

The bootstrap image's job is done. From now on manage the host via the flake.

---

## Troubleshooting

### SSH host key changed warning after flake switch

Expected — the ssh-hardening module changes which key types sshd offers. Clear the cached key:

```bash
ssh-keygen -R <ip>
ssh-keygen -R <hostname>
```

### Static IP not applying after flake switch

Cerberus uses a static IP via `networking.interfaces.eth0`. If the NIC name differs:

```bash
ip -br link   # find the real interface name
```

Update `networking.interfaces.<name>` in `hosts/cerberus/default.nix` and rebuild.

### Build fails with sandbox errors

```bash
nix build .#packages.aarch64-linux.cerberus --option sandbox false
```
