# hosts/hephaestus/services/stacks.nix
#
# Systemd services for Hephaestus Docker Compose stacks:
#   - pterodactyl: Panel + MariaDB + Redis
#   - infrared: Minecraft reverse proxy (routes port 25565 by hostname)
#
# TAILSCALE_IP is injected from the flake's net.tailscale.hephaestus so that
# the Panel port binding (${TAILSCALE_IP}:8080:80) stays DRY with flake.nix.

{ config, pkgs, lib, net, ... }:

let
  stacksDir = "/opt/homelab/stacks/hephaestus";
  docker    = "${pkgs.docker}/bin/docker";
in
{
  # ---------------------------------------------------------------------------
  # sops secrets — decrypted at activation into /run/secrets/
  # ---------------------------------------------------------------------------
  sops.secrets.pterodactyl_secrets = {
    sopsFile = ../secrets.yaml;
    owner    = "root";
    group    = "docker";
    mode     = "0440";
  };

  # ---------------------------------------------------------------------------
  # pterodactyl — Pterodactyl Panel + MariaDB + Redis
  # ---------------------------------------------------------------------------
  systemd.services.pterodactyl = {
    description = "pterodactyl Docker Compose stack";
    after    = [ "docker.service" ];
    wants    = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    # TAILSCALE_IP used for the Panel port binding: ${TAILSCALE_IP}:8080:80
    environment = {
      TAILSCALE_IP = net.tailscale.hephaestus;
    };

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.secrets.pterodactyl_secrets.path;
      ExecStart = "${docker} compose --project-directory ${stacksDir}/pterodactyl up --detach --remove-orphans";
      ExecStop  = "${docker} compose --project-directory ${stacksDir}/pterodactyl down";
    };
  };

  # ---------------------------------------------------------------------------
  # infrared — Minecraft reverse proxy
  #
  # Routes port 25565 to game servers by hostname:
  #   mc.0x21.dev  → localhost:25566
  #   atm.0x21.dev → localhost:25567
  #
  # Uses network_mode: host so it can reach Wings-managed servers on localhost.
  # Port 25565 must NOT be assigned as a Pterodactyl allocation — Infrared owns it.
  # ---------------------------------------------------------------------------
  systemd.services.infrared = {
    description = "infrared Minecraft proxy Docker Compose stack";
    after    = [ "docker.service" "network-online.target" ];
    wants    = [ "docker.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${docker} compose --project-directory ${stacksDir}/infrared up --detach --remove-orphans";
      ExecStop  = "${docker} compose --project-directory ${stacksDir}/infrared down";
    };
  };
}
