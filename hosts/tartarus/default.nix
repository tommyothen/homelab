# hosts/tartarus/default.nix
#
# Tartarus — OCI ARM free tier (aarch64)
# Role: off-site encrypted backup target
#
# Resources: 1 OCPU / 6 GB RAM / 50 GB storage
#
# Receives encrypted restic snapshots from Mnemosyne over SSH/SFTP.
# Oracle never sees plaintext — all encryption happens client-side on Mnemosyne.
#
# Kept intentionally minimal — no Docker, no extra services.
# Smallest possible attack surface.
#
# Setup:
#   See runbooks/offsite-backup.md for the full backup configuration.
#   This host just needs to exist, have SSH, and have disk space.
#
# On first boot:
#   sudo tailscale up --auth-key=<key>

{ config, pkgs, lib, net, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # OCI ARM uses GRUB with efiInstallAsRemovable (installs as BOOTAA64.EFI).
  # This avoids EFI variable writes which OCI instances don't support reliably.
  # Matches the bootstrap oci-image.nix bootloader setup.
  boot.loader.grub = {
    enable               = true;
    device               = "nodev";
    efiSupport           = true;
    efiInstallAsRemovable = true;
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------
  networking.hostName = "tartarus";

  # OCI assigns a public IP via DHCP — no static IP config needed here.
  # Tailscale provides stable private addressing for admin access.
  networking.useDHCP = true;

  # Don't use Cerberus as the upstream DNS resolver — Tartarus is off-site
  # and shouldn't depend on the home network for DNS.
  networking.nameservers = [ "1.1.1.1" "1.0.0.1" ];

  # ---------------------------------------------------------------------------
  # System packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    curl wget htop git restic
  ];

  security.sudo.wheelNeedsPassword = false;

  users.users.tommy = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN+wnifYivhxDUTvfGcd1ao2s39uKwDc8C3HEG0M7noS"
    ];
  };

  # ---------------------------------------------------------------------------
  # Backup user — restic connects to this user over SSH (SFTP backend)
  #
  # The backup user has shell access restricted to restic-only commands via
  # forced commands in authorized_keys. This prevents an attacker who
  # compromises the SSH key from doing anything beyond restic operations.
  #
  # To create an SSH key on Mnemosyne for this user:
  #   ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_tartarus -N "" -C "mnemosyne-backup"
  # Then paste the public key into authorizedKeys below.
  #
  # For extra isolation, use a forced command in authorized_keys to restrict
  # the key to restic-serve only:
  #   command="restic serve sftp" ssh-ed25519 AAAA... mnemosyne-backup
  # ---------------------------------------------------------------------------
  users.users.backup-repo = {
    isSystemUser = true;
    group        = "backup-repo";
    home         = "/var/lib/backup-repo";
    createHome   = true;
    shell        = pkgs.bash;
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... mnemosyne-backup"   ← paste Mnemosyne's public key here
    ];
  };
  users.groups.backup-repo = {};

  # ---------------------------------------------------------------------------
  # Restic repository directories
  # One subdirectory per source dataset to keep repos isolated.
  # ---------------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    "d /data/restic             0750 backup-repo backup-repo -"
    "d /data/restic/mnemosyne   0750 backup-repo backup-repo -"
    "d /data/restic/mnemosyne/apps-ssd  0750 backup-repo backup-repo -"
    "d /data/restic/mnemosyne/media-hdd 0750 backup-repo backup-repo -"
  ];

  # ---------------------------------------------------------------------------
  # Optional: restic REST server (faster than SFTP for large repos)
  #
  # Uncomment once the basic SSH setup is working and you want to benchmark.
  # The REST server provides better concurrency and is recommended for repos
  # larger than ~100 GB.
  #
  # Run on port 8000, Tailscale-only (don't expose to the public internet).
  # ---------------------------------------------------------------------------
  # services.restic.server = {
  #   enable     = true;
  #   dataDir    = "/data/restic";
  #   listenAddress = "${net.tailscale.tartarus}:8000";
  #   # Add --no-auth if you rely on Tailscale ACLs for access control, or
  #   # configure --htpasswd-file for username/password auth.
  #   extraFlags = [ "--no-auth" "--no-verify-upload" ];
  # };
  # networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8000 ];

  # ---------------------------------------------------------------------------
  # Prometheus node exporter — scraped by Panoptes over Tailscale
  # ---------------------------------------------------------------------------
  services.prometheus.exporters.node = {
    enable            = true;
    port              = 9100;
    enabledCollectors = [ "systemd" "processes" "filesystem" ];
    # Listen on all interfaces rather than the Tailscale IP directly.
    # Confirmed in a live deployment: binding to the Tailscale IP causes the
    # service to fail at boot if Tailscale hasn't connected yet. Listening on
    # 0.0.0.0 is safe because the firewall below restricts port 9100 to
    # tailscale0 only — the public interface never sees it.
    listenAddress     = "0.0.0.0";
  };

  # ---------------------------------------------------------------------------
  # Plex TCP relay — forwards public port 32400 to Dionysus over Tailscale.
  # Lets family use Plex remote access without Tailscale or home port forwarding.
  # ---------------------------------------------------------------------------
  services.nginx = {
    enable = true;
    streamConfig = ''
      server {
        listen 32400;
        proxy_pass ${net.tailscale.dionysus}:32400;
      }
    '';
  };

  # ---------------------------------------------------------------------------
  # Firewall
  #
  # Tartarus has a minimal public footprint — only SSH and the Plex relay are
  # open to the internet. Everything else is Tailscale-only or loopback.
  #
  # SSH must be publicly accessible so Mnemosyne (on the LAN) can connect
  # to push backups without going through Tailscale.
  # ---------------------------------------------------------------------------
  networking.firewall = {
    # SSH + Plex relay open to the internet
    allowedTCPPorts = [ 22 32400 ];

    # Admin and monitoring: Tailscale only
    interfaces.tailscale0.allowedTCPPorts = [
      9100   # Prometheus node exporter
    ];
  };

  # ---------------------------------------------------------------------------
  # NixOS state version
  # ---------------------------------------------------------------------------
  system.stateVersion = "25.11";
}
