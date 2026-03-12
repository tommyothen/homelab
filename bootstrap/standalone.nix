# bootstrap/standalone.nix — Temporary bootstrap config for fresh NixOS Proxmox VMs
#
# This file layers bootstrap concerns (user account, SSH hardening, Tailscale,
# secrets tooling) on top of the installer-generated configuration.nix. It is
# used as the TOP-LEVEL config during nixos-install, then gets replaced by the
# full flake-based NixOS configuration once the host is provisioned.
#
# Usage:
#   1. Boot the NixOS 25.11 installer ISO on a Proxmox VM (UEFI/OVMF).
#   2. Partition, format, mount at /mnt, then generate the base config:
#        nixos-generate-config --root /mnt
#   3. Fetch this file directly into the target:
#        curl -fsSL https://raw.githubusercontent.com/tommyothen/homelab/main/bootstrap/standalone.nix \
#          -o /mnt/etc/nixos/standalone.nix
#   4. Install using this file as the entry point:
#        nixos-install --root /mnt -I nixos-config=/mnt/etc/nixos/standalone.nix
#   5. Reboot, SSH in via the Proxmox bridge IP, then authenticate Tailscale:
#        sudo tailscale up
#   6. Grab the host's age public key for .sops.yaml:
#        sops-host-age
#   7. Replace this config with your flake. This file's job is done.
#
# ⚠  KNOWN PITFALL: Do NOT restrict SSH to tailscale0 in this file.
#    Tailscale is unauthenticated on first boot — the only reachable interface
#    is the Proxmox bridge. Binding SSH to tailscale0 here WILL lock you out.

{ config, pkgs, lib, ... }:

{
  # ===========================================================================
  # Imports
  # ===========================================================================
  # We import the installer-generated configuration.nix, which in turn imports
  # hardware-configuration.nix. A relative path is used because Nix resolves
  # it relative to the directory containing THIS file, not the working
  # directory of the evaluating process. This works correctly in both contexts:
  #
  #   • During `nixos-install --root /mnt`:
  #     This file is at /mnt/etc/nixos/standalone.nix, so Nix
  #     resolves ./configuration.nix → /mnt/etc/nixos/configuration.nix. ✓
  #
  #   • After reboot (or `nixos-rebuild`):
  #     This file is at /etc/nixos/standalone.nix, so Nix
  #     resolves ./configuration.nix → /etc/nixos/configuration.nix. ✓
  #
  # No absolute paths, no /mnt prefix gymnastics — relative imports Just Work.
  imports = [
    ./configuration.nix
  ];

  # ===========================================================================
  # Nix daemon settings
  # ===========================================================================

  # Enable the flakes feature gate and the new `nix` CLI (nix build, nix flake,
  # etc.). Required for the eventual migration to a flake-managed config.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Trust wheel users so tommy can push to the binary cache, add substituters,
  # and generally interact with the Nix daemon without friction during bootstrap.
  nix.settings.trusted-users = [ "root" "@wheel" ];

  # ===========================================================================
  # User account
  # ===========================================================================

  users.users.tommy = {
    isNormalUser = true;
    description  = "Tommy";
    extraGroups  = [ "wheel" ];  # sudo access
    shell        = pkgs.bash;    # switching to zsh/fish happens in the flake config

    # Key-only auth — this is the sole way to log in.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN+wnifYivhxDUTvfGcd1ao2s39uKwDc8C3HEG0M7noS"
    ];
  };

  # Passwordless sudo for the wheel group. This is a bootstrap convenience so
  # you're not blocked during initial provisioning. Tighten or remove this once
  # the machine is under full config management.
  security.sudo.wheelNeedsPassword = false;

  # ===========================================================================
  # SSH hardening
  # ===========================================================================

  services.openssh = {
    enable = true;

    # Ensure only the ed25519 host key is generated. This is the key that
    # sops-host-age will derive the age public key from. RSA/ECDSA host keys
    # are unnecessary and increase the attack surface.
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];

    settings = {
      # ── Authentication ────────────────────────────────────────────────
      # Key-only. No passwords, no keyboard-interactive, no root login.
      PasswordAuthentication       = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin              = "no";
      MaxAuthTries                 = 3;

      # ── Cryptographic policy ──────────────────────────────────────────
      # Modern algorithms only. These are comma-separated strings because
      # the NixOS openssh settings module writes them verbatim into
      # sshd_config, which expects this format.

      # ChaCha20 first (constant-time, doesn't need AES-NI), then AES-GCM.
      Ciphers = [ "chacha20-poly1305@openssh.com" "aes256-gcm@openssh.com" "aes128-gcm@openssh.com" ];

      # Encrypt-then-MAC only. The -etm variants are strictly superior to
      # their non-etm counterparts and the only ones worth keeping.
      Macs = [ "hmac-sha2-512-etm@openssh.com" "hmac-sha2-256-etm@openssh.com" ];

      # curve25519-sha256 is the workhorse. The @libssh.org alias exists
      # because older OpenSSH versions used that name — including both
      # ensures broad client compatibility. sntrup761 adds post-quantum
      # hybrid key exchange for forward secrecy against future quantum
      # adversaries.
      KexAlgorithms = [ "curve25519-sha256" "curve25519-sha256@libssh.org" "sntrup761x25519-sha512@openssh.com" ];
    };
  };

  # ===========================================================================
  # Networking & firewall
  # ===========================================================================

  # ⚠  CRITICAL: SSH is open on ALL interfaces here. Read before changing.
  #
  # On first boot, Tailscale is installed but NOT authenticated. The only way
  # to reach this machine is via the Proxmox bridge IP. If you restrict SSH
  # to tailscale0 (e.g. via networking.firewall.interfaces.tailscale0), you
  # WILL be locked out with no way to recover short of console access.
  #
  # The intended workflow is:
  #   1. Boot with SSH open everywhere (this file)
  #   2. SSH in via bridge IP, run `sudo tailscale up`
  #   3. Replace this config with the full flake config, which can then
  #      safely restrict SSH to tailscale0
  #
  # Do NOT tighten the firewall in this file. That's the flake config's job.
  networking.firewall = {
    enable = true;

    # SSH globally — see the warning above.
    allowedTCPPorts = [ 22 ];

    # Tailscale's WireGuard tunnel uses UDP 41641 for direct peer
    # connections. Without this, Tailscale falls back to DERP relays
    # which adds latency.
    allowedUDPPorts = [ 41641 ];
  };

  # Enable the Tailscale daemon. After first boot, authenticate with:
  #   sudo tailscale up
  # or, if this host should be a subnet router / exit node:
  #   sudo tailscale up --advertise-exit-node --advertise-routes=10.0.0.0/24
  services.tailscale.enable = true;

  # ===========================================================================
  # Packages
  # ===========================================================================

  environment.systemPackages = with pkgs; [
    # ── General utilities ───────────────────────────────────────────────
    git
    curl
    wget
    htop

    # ── Secrets tooling ─────────────────────────────────────────────────
    # Needed to bootstrap sops-nix. Once the flake config takes over,
    # these are typically pulled in as flake inputs or devShell deps.
    sops
    age
    ssh-to-age

    # ── sops-host-age helper ────────────────────────────────────────────
    # Derives this host's age public key from its SSH ed25519 host key.
    # You need this key to add the host to .sops.yaml so sops-nix can
    # decrypt secrets for it.
    #
    # Usage:
    #   $ sops-host-age
    #   age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    #
    # Then add it to .sops.yaml:
    #   keys:
    #     - &this-hostname age1xxxxxxxxx...
    #   creation_rules:
    #     - path_regex: hosts/this-hostname/.*
    #       key_groups:
    #         - age:
    #           - *this-hostname
    (writeShellScriptBin "sops-host-age" ''
      set -euo pipefail
      KEY="/etc/ssh/ssh_host_ed25519_key.pub"
      if [ ! -f "$KEY" ]; then
        echo "ERROR: $KEY not found." >&2
        echo "Has sshd generated host keys yet? Try: sudo systemctl start sshd" >&2
        exit 1
      fi
      ${ssh-to-age}/bin/ssh-to-age < "$KEY"
    '')
  ];

  # ===========================================================================
  # Miscellaneous
  # ===========================================================================

  # NOTE: system.stateVersion is intentionally NOT set here. The installer-
  # generated configuration.nix already sets it to match the NixOS release
  # you installed from. Setting it in two places causes a NixOS module
  # conflict. Leave it to configuration.nix.
}
