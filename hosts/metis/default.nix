# hosts/metis/default.nix
#
# Metis — Raspberry Pi 4B (aarch64)
# Role: AI co-DevOps assistant running OpenClaw
#
# Phase 1 (read-only): polls Prometheus, Proxmox API, TrueNAS API, generates
#   health summaries, posts to Discord.
# Phase 2 (assisted): POSTs action requests to Panoptes Action Gateway; a
#   human must approve in Discord before anything executes.
#
# OpenClaw (https://github.com/openclaw/openclaw) is a Node.js ≥ 22 tool.
# Discord is a native built-in channel — no separate bot code needed.
# Packaged via vendored derivation in packages/openclaw/ (buildNpmPackage).
# Config:  ~/.openclaw/openclaw.json  (XDG_CONFIG_HOME → /var/lib/metis/.config)

{ config, pkgs, lib, net, ... }:

let
  deploy-watcher = pkgs.writeShellApplication {
    name = "deploy-watcher";
    runtimeInputs = [ pkgs.git pkgs.curl pkgs.jq ];
    text = builtins.readFile ../../scripts/deploy-watcher.sh;
  };
in
{
  imports = [ ./hardware-configuration.nix ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ---------------------------------------------------------------------------
  # sops secrets
  # ---------------------------------------------------------------------------
  sops.secrets.openclaw_secrets = {
    sopsFile = ./secrets.yaml;
    owner    = "metis";
    mode     = "0400";
  };

  sops.secrets.metis_github_deploy_key = {
    sopsFile = ./secrets.yaml;
    key      = "github_deploy_key";
    owner    = "metis";
    mode     = "0400";
    path     = "/var/lib/metis/.ssh/id_ed25519";
  };

  sops.secrets.metis_gh_token = {
    sopsFile = ./secrets.yaml;
    key      = "gh_token";
    owner    = "metis";
    mode     = "0400";
  };

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------
  networking.hostName = "metis";

  networking.interfaces.eth0.ipv4.addresses = [
    { address = net.hosts.metis; prefixLength = net.prefixLength; }
  ];
  networking.defaultGateway = net.gateway;
  networking.nameservers    = [ net.hosts.cerberus "1.1.1.1" ];  # Pi-hole primary, Cloudflare fallback

  # ---------------------------------------------------------------------------
  # System packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    curl wget htop git gh
    openclaw
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
  # metis system user
  # ---------------------------------------------------------------------------
  users.users.metis = {
    isSystemUser = true;
    group        = "metis";
    home         = "/var/lib/metis";
    createHome   = true;
    description  = "Metis OpenClaw agent user";
  };
  users.groups.metis = {};

  # ---------------------------------------------------------------------------
  # Git configuration for the metis user
  # ---------------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    "d /var/lib/metis/.ssh 0700 metis metis -"
  ];

  # Git identity for commits and PRs
  environment.etc."gitconfig-metis" = {
    text = ''
      [user]
        name = Metis
        email = metis@homelab
      [safe]
        directory = /var/lib/metis/homelab
    '';
    mode = "0444";
  };

  # Clone the homelab repo on first boot (if not already present)
  systemd.services.metis-repo-clone = {
    description = "Clone homelab repo for Metis";
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "!/var/lib/metis/homelab";
    serviceConfig = {
      Type = "oneshot";
      User = "metis";
      Group = "metis";
      Environment = [
        "HOME=/var/lib/metis"
        "GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=accept-new -i /var/lib/metis/.ssh/id_ed25519"
        "GIT_CONFIG_GLOBAL=/etc/gitconfig-metis"
      ];
      ExecStart = "${pkgs.git}/bin/git clone git@github.com:tommyothen/homelab.git /var/lib/metis/homelab";
      RemainAfterExit = true;
    };
  };

  # ---------------------------------------------------------------------------
  # OpenClaw systemd service
  #
  # Binary provided by pkgs.openclaw via the openclaw-nix overlay (see flake.nix).
  # No npm at runtime — fully reproducible, pinned by flake.lock.
  #
  # Env layout (all under /var/lib/metis so ProtectSystem=full is enough):
  #   HOME            = /var/lib/metis
  #   XDG_CONFIG_HOME = /var/lib/metis/.config  ← openclaw.json lives here
  #
  # Credentials are injected via sops-nix EnvironmentFile (see sops.secrets
  # above). Contains: OPENCLAW_GATEWAY_TOKEN, DISCORD_BOT_TOKEN,
  # ACTION_GATEWAY_URL, ACTION_GATEWAY_TOKEN, OPENCLAW_HOOKS_TOKEN.
  # OpenAI Codex auth uses OAuth device flow (token stored in XDG_CONFIG_HOME).
  # ---------------------------------------------------------------------------
  systemd.services.openclaw = {
    description   = "Metis OpenClaw AI agent";
    documentation = [ "https://github.com/openclaw/openclaw" ];

    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HOME               = "/var/lib/metis";
      XDG_CONFIG_HOME    = "/var/lib/metis/.config";
      GIT_CONFIG_GLOBAL  = "/etc/gitconfig-metis";
      GIT_SSH_COMMAND    = "ssh -o StrictHostKeyChecking=yes -i /var/lib/metis/.ssh/id_ed25519";
    };

    serviceConfig = {
      User             = "metis";
      Group            = "metis";
      WorkingDirectory = "/var/lib/metis";
      EnvironmentFile  = [
        config.sops.secrets.openclaw_secrets.path
        config.sops.secrets.metis_gh_token.path
      ];

      ExecStart = "${pkgs.openclaw}/bin/openclaw gateway";

      Restart    = "on-failure";
      RestartSec = "30s";

      # Hardening — full (not strict) so writes to /var/lib/metis are allowed
      NoNewPrivileges = true;
      PrivateTmp      = true;
      ProtectSystem   = "full";
      ReadWritePaths  = [ "/var/lib/metis" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Deploy watcher — poll origin/main and request rebuilds
  # ---------------------------------------------------------------------------
  systemd.services.deploy-watcher = {
    description = "Poll origin/main and request rebuilds for changed hosts";
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "metis";
      Group = "metis";
      WorkingDirectory = "/var/lib/metis";
      Environment = [
        "HOME=/var/lib/metis"
        "GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=yes -i /var/lib/metis/.ssh/id_ed25519"
      ];
      EnvironmentFile = [
        config.sops.secrets.openclaw_secrets.path
      ];
      ExecStart = "${deploy-watcher}/bin/deploy-watcher";
      # Hardening
      NoNewPrivileges = true;
      PrivateTmp      = true;
      ProtectSystem   = "full";
      ReadWritePaths  = [ "/var/lib/metis" ];
    };
  };

  systemd.timers.deploy-watcher = {
    description = "Run deploy-watcher every 5 minutes";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "2min";
      OnUnitActiveSec = "5min";
      Unit            = "deploy-watcher.service";
    };
  };

  # ---------------------------------------------------------------------------
  # Prometheus node exporter
  # ---------------------------------------------------------------------------
  services.prometheus.exporters.node = {
    enable            = true;
    port              = 9100;
    enabledCollectors = [ "systemd" "processes" ];
    # Listen on all interfaces — firewall restricts port 9100 to tailscale0 only.
    # Binding to the Tailscale IP directly causes failure if Tailscale isn't up yet.
    listenAddress     = "0.0.0.0";
  };

  # Node exporter + OpenClaw webhook gateway — reachable via Tailscale only.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 9100 18789 ];

  # ---------------------------------------------------------------------------
  # NixOS state version
  # ---------------------------------------------------------------------------
  system.stateVersion = "25.11";
}
