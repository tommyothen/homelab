# hosts/panoptes/services/action-gateway.nix
#
# NixOS systemd service for the Action Gateway.
#
# The gateway runs as a native systemd service (not Docker) because it needs
# to execute shell scripts that SSH to other hosts, and needs the same SSH
# agent/key material available on the host.
#
# Prerequisites before enabling this module:
#   1. The homelab repo must be checked out (or deployed) at /opt/homelab.
#   2. Encrypt hosts/panoptes/secrets.yaml with sops and deploy via nixos-rebuild.
#      Secrets are decrypted at activation into /run/secrets/action_gateway_secrets.
#   3. The action-gateway SSH key (~action-gateway/.ssh/id_ed25519) must be
#      authorised on each target host's deploy user.
#   4. A Discord bot token must be in hosts/panoptes/secrets.yaml.

{ config, pkgs, lib, net, ... }:

let
  # Python environment with all dependencies declared in requirements.txt.
  # Package names in nixpkgs may differ from PyPI names — adjust if needed.
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    fastapi
    uvicorn
    pyyaml
    aiosqlite
    # discord.py is packaged as "discordpy" in nixpkgs
    discordpy
    # uvicorn[standard] extras
    httptools
    websockets
    uvloop
  ]);

  serviceName = "action-gateway";
  serviceDir  = "/opt/homelab/services/action-gateway";
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
    description  = "Action Gateway service user";
    # The user needs an SSH key to reach Dionysus and other target hosts.
    # Generate one and add the public key to each target's authorised_keys:
    #   sudo -u action-gateway ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  };

  users.groups.${serviceName} = {};

  # ---------------------------------------------------------------------------
  # sops secret — Discord token, channel ID, approver role ID, gateway token
  # ---------------------------------------------------------------------------
  sops.secrets.action_gateway_secrets = {
    sopsFile = ../secrets.yaml;
    owner    = serviceName;
    mode     = "0400";
  };

  # ---------------------------------------------------------------------------
  # systemd service
  # ---------------------------------------------------------------------------
  systemd.services.${serviceName} = {
    description = "Action Gateway (FastAPI + Discord bot)";
    documentation = [ "file://${serviceDir}/README.md" ];

    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User             = serviceName;
      Group            = serviceName;
      WorkingDirectory = serviceDir;

      # Secrets decrypted at activation by sops-nix — no .env file needed.
      EnvironmentFile = config.sops.secrets.action_gateway_secrets.path;
      Environment = [ "DB_PATH=${dataDir}/audit.db" ];

      ExecStart = lib.concatStringsSep " " [
        "${pythonEnv}/bin/uvicorn"
        "main:app"
        "--host" net.tailscale.panoptes   # Bind directly to Panoptes Tailscale IP only
        "--port" "8080"
        "--log-level" "info"
      ];

      Restart    = "on-failure";
      RestartSec = "10s";

      # --- Hardening ---
      UMask            = "0077";
      NoNewPrivileges  = true;
      PrivateTmp       = true;
      ProtectSystem    = "strict";
      # The service needs write access to its data dir and the repo checkout.
      ReadWritePaths   = [ dataDir ];
      ReadOnlyPaths    = [ serviceDir ];
      ProtectHome      = true;
      ProtectKernelTunables = true;
      ProtectKernelModules  = true;
      ProtectControlGroups  = true;
      RestrictNamespaces    = true;
      LockPersonality       = true;
      RestrictRealtime      = true;

      # Allow outbound SSH (port 22) and HTTPS (Discord WebSocket / API).
      # If you use a very restrictive nftables setup you may need to adjust.
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Firewall — open port 8080 on the Tailscale interface only.
  #
  # NixOS's per-interface firewall rule means port 8080 is never reachable
  # on the LAN (eth0/ens18) or WAN — only from Tailscale peers (including
  # Metis), which is exactly what we want.
  # ---------------------------------------------------------------------------
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8080 ];
}
