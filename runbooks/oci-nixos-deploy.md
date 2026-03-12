# Runbook: Deploy NixOS ARM64 Instances on Oracle Cloud (OCI)

> **Scope:** Build a NixOS ARM64 image, upload to OCI, and launch two free-tier A1.Flex instances with SSH/Tailscale/sops bootstrap, then hand off to flake-managed configuration.
>
> **Estimated time:** ~60 minutes (mostly waiting for upload/import)
>
> **Last tested:** 2026-03-06 on NixOS 25.05, OCI uk-london-1, Terraform 1.x, Determinate Nix on WSL2

---

## Free Tier Allocation

| Instance | OCPUs | RAM | Boot Volume | Role |
|----------|-------|-----|-------------|------|
| Hephaestus | 3 | 18 GB | 150 GB | Game servers (Minecraft + Pterodactyl) |
| Tartarus | 1 | 6 GB | 50 GB | Off-site backup target |
| **Total (free tier limit)** | **4** | **24 GB** | **200 GB** | |

---

## Prerequisites

- OCI account with free tier ARM allocation available
- WSL2 Ubuntu with `nix`, `terraform`, and `oci` CLI installed
- aarch64 cross-compilation enabled (QEMU binfmt)
- OCI API key configured (`oci setup config`)
- SSH ed25519 keypair for your admin user

---

## 1) Enable aarch64 cross-compilation (one-time WSL setup)

```bash
sudo apt install qemu-user-static binfmt-support
sudo systemctl restart systemd-binfmt
```

Verify:

```bash
ls /proc/sys/fs/binfmt_misc/qemu-aarch64
# Must exist
```

Configure Nix (Determinate Nix uses `nix.custom.conf`; standard Nix uses `nix.conf`):

```bash
cat <<'EOF' | sudo tee /etc/nix/nix.custom.conf
extra-platforms = aarch64-linux
extra-sandbox-paths = /usr/bin/qemu-aarch64-static
trusted-users = root tommy
EOF

sudo systemctl restart nix-daemon
```

Verify:

```bash
nix build nixpkgs#legacyPackages.aarch64-linux.hello --no-link
# Must complete without errors
```

---

## 2) Create OCI console resources

### Object Storage bucket

**Storage -> Object Storage -> Buckets -> Create Bucket**

| Setting | Value |
|---|---|
| Name | `nixos-images` |
| Storage Tier | Standard |

### VCN (Virtual Cloud Network)

**Networking -> Virtual Cloud Networks -> Start VCN Wizard -> Create VCN with Internet Connectivity**

| Setting | Value |
|---|---|
| VCN Name | `nixos-vcn` |
| VCN CIDR | `10.0.0.0/16` |
| Public Subnet CIDR | `10.0.0.0/24` |

> **CRITICAL:** After the wizard completes, verify the route table has a `0.0.0.0/0 -> internet gateway` rule.
> Go to **VCN -> Route Tables -> Default Route Table** and check.
> If this rule is missing, instances will boot with public IPs but be **completely unreachable**.
> Terraform's `network.tf` manages this, but the wizard should have created it.

### Security list ingress rules

**VCN -> Public Subnet -> Default Security List -> Add Ingress Rules**

| Source CIDR | Protocol | Dest Port | Description |
|---|---|---|---|
| `0.0.0.0/0` | TCP | 22 | SSH (bootstrap; remove after Tailscale) |
| `0.0.0.0/0` | UDP | 41641 | Tailscale WireGuard |

### Collect OCIDs

| Value | Where to find it |
|---|---|
| `tenancy_ocid` | Profile menu -> Tenancy -> OCID |
| `user_ocid` | Profile menu -> My Profile -> OCID |
| `compartment_ocid` | Same as tenancy OCID for root compartment |
| `vcn_ocid` | Networking -> VCNs -> nixos-vcn -> OCID |
| `subnet_ocid` | VCN -> Public Subnet -> OCID |
| `namespace` | Tenancy Details -> Object Storage Settings |
| `fingerprint` | My Profile -> API Keys -> fingerprint |
| `region` | Top bar (e.g. `uk-london-1`) |

### Look up image capability schema version

```bash
oci compute global-image-capability-schema list \
  --all --query 'data[0]."current-version-name"' --raw-output
```

Save this UUID -- you'll need it for `terraform/oci/image.tf`.

---

## 3) Build the NixOS image

```bash
cd bootstrap/oci/
nix build .#packages.aarch64-linux.default
ls -lh result/
# Expect: nixos-image-oci-*.qcow2 (~2.7 GB)
```

> Cross-compilation via QEMU is slow. Most packages come from the binary cache;
> the QEMU-emulated steps (image assembly) take the bulk of the time.
> If the build fails with sandbox errors, try `--option sandbox false`.

---

## 4) Deploy with Terraform

```bash
cd terraform/oci/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your OCI values (see .example file)
```

> **Use absolute paths.** Terraform does not expand `~`.

Deploy:

```bash
terraform init
terraform plan    # Expect ~8 resources
terraform apply   # Type 'yes'
```

Expect ~20 minutes: image upload (~9 min) + image import (~7 min) + instance launch (~2 min).

```
Outputs:
  hephaestus_ip = "144.x.x.x"
  tartarus_ip   = "150.x.x.x"
```

---

## 5) First login

```bash
HEPH_IP=$(terraform output -raw hephaestus_ip)
ssh tommy@$HEPH_IP

TART_IP=$(terraform output -raw tartarus_ip)
ssh tommy@$TART_IP
```

Accept the host key fingerprint.

> If SSH hangs, see Troubleshooting -> "Instance unreachable" below.

---

## 6) Post-boot checklist (repeat per instance)

### Authenticate Tailscale

```bash
sudo tailscale up
```

Open the URL shown to authorize the node.

### Get host age key

```bash
sops-host-age
# Outputs: age1...
```

Add to `.sops.yaml` in homelab repo root:

```yaml
keys:
  - &tartarus    age1...   # from sops-host-age on Tartarus
  - &hephaestus  age1...   # from sops-host-age on Hephaestus
```

### Update flake.nix IPs

Fill in `net.external` and `net.tailscale` IPs in `flake.nix`:

```nix
external = {
  tartarus   = "<OCI public IP>";
  hephaestus = "<OCI public IP>";
};
tailscale = {
  tartarus   = "100.x.x.x";   # tailscale ip -4  (on tartarus)
  hephaestus = "100.x.x.x";   # tailscale ip -4  (on hephaestus)
};
```

### Validate baseline state

```bash
sudo sshd -T | grep -E 'ciphers|macs|kexalgorithms|passwordauthentication|permitrootlogin'
tailscale status
nix flake metadata nixpkgs
```

---

## 7) Hand off to flake config

Deploy the production NixOS config from the homelab repo.

> **Non-NixOS host (e.g. Ubuntu WSL):** Use `nix run nixpkgs#nixos-rebuild` and set
> `--build-host` to the same target so the build happens on the aarch64 instance itself,
> avoiding cross-compilation entirely.
>
> **Note:** `--use-remote-sudo` is deprecated — use `--sudo` instead.

```bash
# From a NixOS host
nixos-rebuild switch --flake .#tartarus --target-host tommy@<tailscale-ip> --sudo
nixos-rebuild switch --flake .#hephaestus --target-host tommy@<tailscale-ip> --sudo

# From Ubuntu WSL (or any non-NixOS host)
nix run nixpkgs#nixos-rebuild -- switch \
  --flake ~/path/to/homelab#tartarus \
  --target-host tommy@<tailscale-ip> \
  --build-host tommy@<tailscale-ip> \
  --sudo
```

The bootstrap configuration's job is done. From now on, manage these hosts
the same as any other NixOS machine in the flake.

---

## 8) Harden

After both instances are on Tailscale and running flake config:

1. Remove public SSH security list rule (access via Tailscale only)
2. Optionally release public IPs (Compute -> Instance -> Attached VNICs -> remove public IP)
3. Delete the Object Storage qcow2 (no longer needed after image import)

---

## Troubleshooting

### Instance unreachable (SSH hangs, ping 100% loss)

**Most likely: missing internet gateway / route table rule.**

OCI instances can be RUNNING with public IPs, but if the VCN route table has no `0.0.0.0/0 -> internet gateway` rule, no traffic reaches them. The instance itself is fine (sshd running, network configured) -- the problem is at the VCN layer.

Check route table in console: **VCN -> Route Tables -> Default Route Table**.
If empty, Terraform's `network.tf` should fix this on next `terraform apply`.

To debug from the boot log:

```bash
# Capture console history
oci compute console-history capture --instance-id "INSTANCE_OCID"

# Fetch boot log (use console-history OCID from output above)
oci compute console-history get-content \
  --instance-console-history-id "HISTORY_OCID" --file - --length 262144
```

Look for: `<<< NixOS Stage 1 >>>`, `Cloud-init finished`, `Started SSH Daemon`.

### image capability schema: "not a subset" error

OCI's global image capability schema changes over time. Values that were valid previously
may be rejected. Confirmed removals (as of 2026-03):

- `Network.AttachmentType`: `VDPA` removed — valid values: `PARAVIRTUALIZED`, `E1000`, `VFIO`
- `Storage.BootVolumeType`: `NVME` removed — valid values: `PARAVIRTUALIZED`, `ISCSI`, `SCSI`, `IDE`

Fix: remove the invalid value from `terraform/oci/image.tf` and re-apply.

### Bootloader: use GRUB, not systemd-boot

OCI ARM instances boot via GRUB with `efiInstallAsRemovable` (installs as `BOOTAA64.EFI`).
Using `boot.loader.systemd-boot.enable = true` will fail at activation because `bootctl status`
can't write to EFI variables on OCI. Use this instead:

```nix
boot.loader.grub = {
  enable                = true;
  device                = "nodev";
  efiSupport            = true;
  efiInstallAsRemovable = true;
};
```

### Prometheus node exporter fails to start (Tailscale race condition)

Binding the exporter to the Tailscale IP directly causes it to fail at boot if Tailscale
hasn't connected yet. Listen on `0.0.0.0` instead and rely on the firewall to restrict
access to `tailscale0`. Confirmed in live deployment on Tartarus (2026-03).

```nix
services.prometheus.exporters.node.listenAddress = "0.0.0.0";
```

### OCI console connections require RSA keys

The `oci compute instance-console-connection create` API rejects ed25519 keys.
Generate a temporary RSA key for console access:

```bash
ssh-keygen -t rsa -b 2048 -f /tmp/oci-console-key -N ""
oci compute instance-console-connection create \
  --instance-id <ocid> \
  --ssh-public-key-file /tmp/oci-console-key.pub
```

Connect with `HostKeyAlgorithms=+ssh-rsa` since OCI's console service offers `ssh-rsa`
which modern OpenSSH rejects by default.

### sudo locked out after first nixos-rebuild switch

The bootstrap config sets `security.sudo.wheelNeedsPassword = false`. If the full host
config doesn't include this, sudo will require a password — but no password is set.
Recovery requires reprovisioning (terminate + recreate from image via Terraform).

All host configs now include `security.sudo.wheelNeedsPassword = false` to prevent this.

### "Shape not compatible with image" error

Shape management resource didn't apply. Manual fix:
**Custom Images -> image -> Edit details -> Compatible Shapes -> add VM.Standard.A1.Flex**
(min 1 OCPU / 6 GB, max 4 OCPU / 24 GB).

### Image capabilities schema version error

Version name is a UUID, not a date string. `"2024-03-27"` does **not** work.

```bash
oci compute global-image-capability-schema list \
  --all --query 'data[0]."current-version-name"' --raw-output
```

### Cross-compilation fails in WSL

```bash
# Verify binfmt
cat /proc/sys/fs/binfmt_misc/qemu-aarch64   # should show "enabled"

# Re-register after WSL reboot
sudo systemctl restart systemd-binfmt

# Fallback
nix build .#packages.aarch64-linux.default --option sandbox false
```

### Importing existing VCN resources into Terraform

If the VCN wizard already created an internet gateway and route table:

```bash
terraform import oci_core_internet_gateway.igw "IGW_OCID"
terraform import oci_core_route_table.rt "ROUTE_TABLE_OCID"
terraform plan   # Should show no changes
```

---

## Boot Sequence Reference

For debugging, this is what a healthy OCI NixOS boot looks like (from serial console):

1. UEFI firmware loads from boot volume (PARAVIRTUALIZED)
2. Linux kernel boots via EFI stub (systemd-boot)
3. NixOS Stage 1: initrd, virtio modules, fsck, mount root
4. NixOS Stage 2: systemd, firewall, udev, growpart (expands root to full boot volume)
5. cloud-init (init-local): discovers `DataSourceOpenStackLocal`, ephemeral DHCP on `enp0s6`
6. cloud-init writes `/etc/systemd/network/10-cloud-init-enp0s6.network` (DHCP4 + DHCP6)
7. systemd-networkd: permanent DHCP, assigns private IP (e.g. `10.0.0.x/24`)
8. cloud-init (config): generates SSH host keys, writes root authorized_keys
9. sshd starts, listening on all interfaces
10. cloud-init (final): system reaches multi-user target

Total boot time: ~45 seconds.

> cloud-init writes SSH keys to root, but `PermitRootLogin = "no"` blocks root SSH.
> Your `tommy` user's authorized key is baked into the NixOS config.

---

## File Structure

```
homelab/
├── bootstrap/oci/
│   ├── flake.nix              # builds the OCI ARM64 qcow2 image
│   ├── configuration.nix      # bootstrap config baked into the image
│   └── result/                # build output (gitignored)
└── terraform/oci/
    ├── provider.tf
    ├── variables.tf
    ├── image.tf
    ├── network.tf
    ├── instances.tf
    ├── outputs.tf
    ├── terraform.tfvars.example
    ├── terraform.tfvars        # secrets -- do not commit
    └── terraform.tfstate       # state -- do not commit
```
