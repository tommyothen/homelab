# bootstrap/pi/configuration.nix
#
# Minimal NixOS configuration baked into the Pi SD card image.
# After first boot: SSH in -> tailscale up -> deploy flake config.
# See runbooks/pi-bootstrap.md for the full procedure.

{ config, pkgs, lib, ... }:

{
  # ===========================================================================
  # Nix daemon settings
  # ===========================================================================

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "root" "@wheel" ];

  # ===========================================================================
  # User account
  # ===========================================================================

  users.users.tommy = {
    isNormalUser = true;
    description  = "Tommy";
    extraGroups  = [ "wheel" ];
    shell        = pkgs.bash;

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN+wnifYivhxDUTvfGcd1ao2s39uKwDc8C3HEG0M7noS"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # ===========================================================================
  # SSH hardening
  # ===========================================================================

  services.openssh = {
    enable = true;

    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];

    settings = {
      PasswordAuthentication       = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin              = "no";
      MaxAuthTries                 = 3;

      Ciphers = [
        "chacha20-poly1305@openssh.com"
        "aes256-gcm@openssh.com"
        "aes128-gcm@openssh.com"
      ];

      Macs = [
        "hmac-sha2-512-etm@openssh.com"
        "hmac-sha2-256-etm@openssh.com"
      ];

      KexAlgorithms = [
        "curve25519-sha256"
        "curve25519-sha256@libssh.org"
        "sntrup761x25519-sha512@openssh.com"
      ];
    };
  };

  # ===========================================================================
  # Networking & firewall
  # ===========================================================================

  # DHCP on first boot — static IP is set in the full flake config.
  networking.useDHCP = true;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ 41641 ];  # Tailscale WireGuard
  };

  services.tailscale.enable = true;

  # ===========================================================================
  # Packages
  # ===========================================================================

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    htop

    # Secrets tooling
    sops
    age
    ssh-to-age

    # sops-host-age helper — prints the age public key derived from the SSH
    # host key. Add this to .sops.yaml after first boot.
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

  system.stateVersion = "25.11";
}
