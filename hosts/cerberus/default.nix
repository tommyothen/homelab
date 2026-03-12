# hosts/cerberus/default.nix
#
# Cerberus — Raspberry Pi 4B
# Role: network gateway, AdGuard Home DNS/ad-block, Tailscale node
#
# After first boot:
#   sudo tailscale up
#
# AdGuard Home first-run:
#   Access http://<cerberus-tailscale-ip>:3000 from a Tailscale client to set
#   your admin password. The web UI is not reachable from the LAN.

{ config, pkgs, lib, net, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Pi 4B uses extlinux — no GRUB or systemd-boot.
  boot.loader.grub.enable                       = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------
  networking.hostName = "cerberus";

  networking.interfaces.eth0.ipv4.addresses = [
    { address = net.hosts.cerberus; prefixLength = net.prefixLength; }
  ];
  networking.defaultGateway = net.gateway;
  # AdGuard Home on localhost handles DNS; it uses upstream resolvers (1.1.1.1)
  # set in its own config below.
  networking.nameservers = [ "127.0.0.1" ];

  # ---------------------------------------------------------------------------
  # System packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    curl wget htop git
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
  # AdGuard Home — native NixOS module
  #
  # DNS rewrites are fully declarative here — no manual UI clicks needed.
  # Most *.0x21.uk hostnames resolve to Panoptes's Tailscale IP (admin-only).
  # Selected home-facing routes (Home Assistant, Plex, Seerr) resolve to
  # Panoptes's LAN IP so non-Tailscale clients can use them.
  #
  # mutableSettings = true: Nix defines the initial/authoritative config, but
  # AdGuard's state file can be edited via the UI and persists across rebuilds
  # (useful for adding extra filter lists, per-client rules, etc.).
  # ---------------------------------------------------------------------------

  # Free port 53 from systemd-resolved's stub listener.
  services.resolved = {
    enable      = true;
    extraConfig = "DNSStubListener=no";
  };

  services.adguardhome = {
    enable          = true;
    mutableSettings = true;

    settings = {
      http = {
        address = "0.0.0.0:3000";   # Web UI — firewall restricts to tailscale0
      };

      dns = {
        bind_hosts    = [ "0.0.0.0" ];
        port          = 53;
        upstream_dns  = [ "1.1.1.1" "1.0.0.1" ];
        bootstrap_dns = [ "1.1.1.1" "1.0.0.1" ];
      };

      # Declarative DNS rewrites.
      # Most *.0x21.uk domains resolve to Panoptes's Tailscale IP, keeping
      # admin routes off the LAN. A small allowlist (home/plex/seerr) points
      # to Panoptes's LAN IP for home-network use.
      #
      # NOTE: rewrites live under filtering (not dns) in AdGuard schema v32+.
      filtering = {
        filtering_enabled = true;
        rewrites = [
          # LAN-facing routes via Traefik LAN entrypoint
          { domain = "home.${net.domain}"; answer = net.hosts.panoptes; enabled = true; }
          { domain = "plex.${net.domain}"; answer = net.hosts.panoptes; enabled = true; }
          { domain = "seerr.${net.domain}"; answer = net.hosts.panoptes; enabled = true; }

          # Default: admin routes stay on Tailscale-only ingress
          { domain = "*.${net.domain}"; answer = net.tailscale.panoptes; enabled = true; }
          { domain = "dionysus";        answer = net.hosts.dionysus;     enabled = true; }
          { domain = "panoptes";        answer = net.hosts.panoptes;     enabled = true; }
          { domain = "cerberus";        answer = net.hosts.cerberus;     enabled = true; }
          { domain = "mnemosyne";       answer = net.hosts.mnemosyne;    enabled = true; }
          { domain = "metis";           answer = net.hosts.metis;        enabled = true; }
        ];
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Firewall
  # ---------------------------------------------------------------------------
  networking.firewall = {
    # DNS port 53: open to the full LAN — every client (including guests)
    # needs DNS resolution. DNS policy decides whether a hostname resolves to
    # Panoptes's Tailscale or LAN ingress.
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
    # AdGuard web UI + node exporter: Tailscale-only — not reachable from the LAN.
    interfaces.tailscale0.allowedTCPPorts = lib.mkAfter [ 3000 9100 ];
  };

  # ---------------------------------------------------------------------------
  # Prometheus node exporter — scraped by Panoptes over Tailscale
  # ---------------------------------------------------------------------------
  services.prometheus.exporters.node = {
    enable            = true;
    port              = 9100;
    enabledCollectors = [ "systemd" "processes" ];
    listenAddress     = "0.0.0.0";
  };
  # ---------------------------------------------------------------------------
  # NixOS state version
  # ---------------------------------------------------------------------------
  system.stateVersion = "25.11";
}
