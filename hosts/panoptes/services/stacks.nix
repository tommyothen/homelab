# hosts/panoptes/services/stacks.nix
#
# Systemd oneshot service for the ingress Docker Compose stack on Panoptes,
# plus Grafana admin password injection via sops-nix.
#
  # Tailscale and LAN IPs are injected into the ingress service environment so
  # docker compose can substitute ${DIONYSUS_TAILSCALE_IP}, ${PANOPTES_LAN_IP},
  # etc. in the stack config — keeping routing values DRY with flake.nix.

{ config, pkgs, lib, net, ... }:

let
  stacksDir = "/opt/homelab/stacks/panoptes";
  docker    = "${pkgs.docker}/bin/docker";
in
{
  # ---------------------------------------------------------------------------
  # sops secrets — decrypted at activation into /run/secrets/
  # ---------------------------------------------------------------------------
  sops.secrets.ingress_secrets = {
    sopsFile = ../secrets.yaml;
    owner    = "root";
    group    = "docker";
    mode     = "0440";
  };

  sops.secrets.grafana_secrets = {
    sopsFile = ../secrets.yaml;
    owner    = "grafana";
    mode     = "0400";
  };

  # ---------------------------------------------------------------------------
  # Inject GF_SECURITY_ADMIN_PASSWORD into the NixOS-native Grafana service.
  # Grafana reads it via: admin_password = "$__env{GF_SECURITY_ADMIN_PASSWORD}"
  # ---------------------------------------------------------------------------
  systemd.services.grafana.serviceConfig.EnvironmentFile =
    config.sops.secrets.grafana_secrets.path;

  # ---------------------------------------------------------------------------
  # ingress — Traefik, Authentik, Homepage, Gatus, Miniflux, Diun,
  #           Speedtest Tracker, Notifiarr, PVE Exporter
  # ---------------------------------------------------------------------------
  systemd.services.ingress = {
    description = "ingress Docker Compose stack";
    after    = [ "docker.service" "var-lib-appdata.mount" ];
    wants    = [ "docker.service" "var-lib-appdata.mount" ];
    wantedBy = [ "multi-user.target" ];

    # IPs from flake.nix — docker compose substitutes ${VAR} in Traefik
    # dynamic configs and stack bindings at runtime.
    environment = {
      PANOPTES_TAILSCALE_IP   = net.tailscale.panoptes;
      PANOPTES_LAN_IP         = net.hosts.panoptes;
      ZEUS_LAN_IP             = net.hosts.zeus;
      HESTIA_LAN_IP           = net.hosts.hestia;
      DIONYSUS_TAILSCALE_IP   = net.tailscale.dionysus;
      CERBERUS_TAILSCALE_IP   = net.tailscale.cerberus;
      HEPHAESTUS_TAILSCALE_IP = net.tailscale.hephaestus;
      ASCLEPIUS_TAILSCALE_IP  = net.tailscale.asclepius;
      METIS_TAILSCALE_IP      = net.tailscale.metis;
      TARTARUS_TAILSCALE_IP   = net.tailscale.tartarus;
      HEPHAESTUS_PUBLIC_IP    = net.external.hephaestus;
    };

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.secrets.ingress_secrets.path;
      ExecStart = "${docker} compose --project-directory ${stacksDir}/ingress up --detach --remove-orphans";
      ExecStop  = "${docker} compose --project-directory ${stacksDir}/ingress down";
    };
  };
}
