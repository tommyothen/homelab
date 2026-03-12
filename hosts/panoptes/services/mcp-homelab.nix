# hosts/panoptes/services/mcp-homelab.nix
#
# NixOS systemd service for the Homelab MCP Server.
#
# Provides read-only observability tools (Prometheus, Loki, container status,
# Tailscale, NixOS generations) via the Model Context Protocol (MCP) for
# Metis's OpenClaw agent.
#
# Listens on 0.0.0.0:8090 — firewalled to tailscale0 only so only Tailscale
# peers (Metis) can connect.
#
# Prerequisites:
#   1. The homelab repo must be checked out at /opt/homelab.
#   2. The mcp-homelab SSH key (~mcp-homelab/.ssh/id_ed25519) must be
#      authorised on each target host's deploy user for container_status
#      and nixos_generations tools.

{ config, pkgs, lib, net, ... }:

let
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    mcp
    httpx
  ]);

  serviceName = "mcp-homelab";
  serviceDir  = "/opt/homelab/services/metis/mcp-homelab";
  dataDir     = "/var/lib/${serviceName}";
in
{
  # ---------------------------------------------------------------------------
  # Dedicated non-root system user
  # ---------------------------------------------------------------------------
  users.users.${serviceName} = {
    isSystemUser = true;
    group        = serviceName;
    home         = dataDir;
    createHome   = true;
    description  = "Homelab MCP server user";
    # SSH key for read-only queries on target hosts:
    #   sudo -u mcp-homelab ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  };

  users.groups.${serviceName} = {};

  # ---------------------------------------------------------------------------
  # systemd service
  # ---------------------------------------------------------------------------
  systemd.services.${serviceName} = {
    description = "Homelab MCP Server (read-only observability tools)";

    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      PROMETHEUS_URL = "http://localhost:9090";
      LOKI_URL       = "http://localhost:3100";
      GATUS_URL      = "http://localhost:8080";
      DEPLOY_USER    = "deploy";
    };

    serviceConfig = {
      User             = serviceName;
      Group            = serviceName;
      WorkingDirectory = serviceDir;

      ExecStart = "${pythonEnv}/bin/python ${serviceDir}/server.py";

      Restart    = "on-failure";
      RestartSec = "10s";

      # --- Hardening ---
      UMask            = "0077";
      NoNewPrivileges  = true;
      PrivateTmp       = true;
      ProtectSystem    = "strict";
      ReadWritePaths   = [ dataDir ];
      ReadOnlyPaths    = [ serviceDir ];
      ProtectHome      = true;
      ProtectKernelTunables = true;
      ProtectKernelModules  = true;
      ProtectControlGroups  = true;
      RestrictNamespaces    = true;
      LockPersonality       = true;
      RestrictRealtime      = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Firewall — open port 8090 on the Tailscale interface only.
  # ---------------------------------------------------------------------------
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8090 ];
}
