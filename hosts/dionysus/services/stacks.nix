# hosts/dionysus/services/stacks.nix
#
# Systemd oneshot services for all Docker Compose stacks on Dionysus.
#
# Secrets are injected via sops-nix EnvironmentFile — no .env files needed.
# Non-secret config is hardcoded directly in each docker-compose.yml.
#
# Stack dependency order:
#   1. media-core   — creates the shared 'media' Docker network
#   2. media-vpn    — joins 'media' network; needs media-core up first
#   3. media-extras — joins 'media' network; needs media-core up first
#   4. books        — joins 'media' network; needs media-core up first
#   5. personal     — standalone network; no dependency on media-core
#   6. paperless    — standalone network; no dependency on media-core

{ config, pkgs, lib, net, ... }:

let
  stacksDir = "/opt/homelab/stacks/dionysus";
  docker    = "${pkgs.docker}/bin/docker";
in
{
  # ---------------------------------------------------------------------------
  # sops secrets — decrypted at activation into /run/secrets/
  # ---------------------------------------------------------------------------
  sops.secrets.media_core_secrets = {
    sopsFile = ../secrets.yaml;
    owner    = "root";
    group    = "docker";
    mode     = "0440";
  };

  sops.secrets.media_vpn_secrets = {
    sopsFile = ../secrets.yaml;
    owner    = "root";
    group    = "docker";
    mode     = "0440";
  };

  sops.secrets.paperless_secrets = {
    sopsFile = ../secrets.yaml;
    owner    = "root";
    group    = "docker";
    mode     = "0440";
  };

  sops.secrets.personal_secrets = {
    sopsFile = ../secrets.yaml;
    owner    = "root";
    group    = "docker";
    mode     = "0440";
  };

  # ---------------------------------------------------------------------------
  # media-core — Plex, Sonarr, Radarr, Prowlarr, Seerr, SABnzbd
  # ---------------------------------------------------------------------------
  systemd.services.media-core = {
    description = "media-core Docker Compose stack";
    after    = [ "docker.service" "var-lib-appdata.mount" "data-media.mount" "data-downloads.mount" ];
    wants    = [ "docker.service" "var-lib-appdata.mount" "data-media.mount" "data-downloads.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.secrets.media_core_secrets.path;
      ExecStart = "${docker} compose --project-directory ${stacksDir}/media-core up --detach --remove-orphans";
      ExecStop  = "${docker} compose --project-directory ${stacksDir}/media-core down";
    };
  };

  # ---------------------------------------------------------------------------
  # media-vpn — Gluetun + qBittorrent (VPN-tunnelled torrent fallback)
  # ---------------------------------------------------------------------------
  systemd.services.media-vpn = {
    description = "media-vpn Docker Compose stack";
    after    = [ "docker.service" "var-lib-appdata.mount" "data-media.mount" "data-downloads.mount" "media-core.service" ];
    wants    = [ "docker.service" "var-lib-appdata.mount" "data-media.mount" "data-downloads.mount" "media-core.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.secrets.media_vpn_secrets.path;
      ExecStart = "${docker} compose --project-directory ${stacksDir}/media-vpn up --detach --remove-orphans";
      ExecStop  = "${docker} compose --project-directory ${stacksDir}/media-vpn down";
    };
  };

  # ---------------------------------------------------------------------------
  # media-extras — Seanime, Tdarr (joins media network)
  # No secrets — all config hardcoded in compose.
  # ---------------------------------------------------------------------------
  systemd.services.media-extras = {
    description = "media-extras Docker Compose stack";
    after    = [ "docker.service" "var-lib-appdata.mount" "media-core.service" ];
    wants    = [ "docker.service" "var-lib-appdata.mount" "media-core.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${docker} compose --project-directory ${stacksDir}/media-extras up --detach --remove-orphans";
      ExecStop  = "${docker} compose --project-directory ${stacksDir}/media-extras down";
    };
  };

  # ---------------------------------------------------------------------------
  # books — LazyLibrarian, Calibre-Web, Shelfmark (joins media network)
  # No secrets — all config hardcoded in compose.
  # ---------------------------------------------------------------------------
  systemd.services.books = {
    description = "books Docker Compose stack";
    after    = [ "docker.service" "var-lib-appdata.mount" "media-core.service" ];
    wants    = [ "docker.service" "var-lib-appdata.mount" "media-core.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${docker} compose --project-directory ${stacksDir}/books up --detach --remove-orphans";
      ExecStop  = "${docker} compose --project-directory ${stacksDir}/books down";
    };
  };

  # ---------------------------------------------------------------------------
  # personal — Mealie, Actual Budget, Wallos, Stirling PDF, IT-Tools
  # ---------------------------------------------------------------------------
  systemd.services.personal = {
    description = "personal Docker Compose stack";
    after    = [ "docker.service" "var-lib-appdata.mount" ];
    wants    = [ "docker.service" "var-lib-appdata.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.secrets.personal_secrets.path;
      ExecStart = "${docker} compose --project-directory ${stacksDir}/personal up --detach --remove-orphans";
      ExecStop  = "${docker} compose --project-directory ${stacksDir}/personal down";
    };
  };

  # ---------------------------------------------------------------------------
  # paperless — Paperless-ngx, PostgreSQL, Redis
  # ---------------------------------------------------------------------------
  systemd.services.paperless = {
    description = "paperless Docker Compose stack";
    after    = [ "docker.service" "var-lib-appdata.mount" ];
    wants    = [ "docker.service" "var-lib-appdata.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.secrets.paperless_secrets.path;
      ExecStart = "${docker} compose --project-directory ${stacksDir}/paperless up --detach --remove-orphans";
      ExecStop  = "${docker} compose --project-directory ${stacksDir}/paperless down";
    };
  };
}
