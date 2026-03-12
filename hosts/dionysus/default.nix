# hosts/dionysus/default.nix
#
# Dionysus — NixOS VM on Zeus (x86_64)
# Role: media services — Plex, Arr suite, Seerr, SABnzbd, qBittorrent
#
# Docker Compose stacks are managed as NixOS systemd oneshot services.
# See ./services/stacks.nix for stack definitions and secret injection.
# The host config focuses on: NFS mounts, Docker, the deploy user, and
# node-level observability.

{ config, pkgs, lib, net, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./services/stacks.nix
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------
  networking.hostName = "dionysus";

  # Static IP — adjust to match your LAN.
  networking.interfaces.ens18.ipv4.addresses = [
    { address = net.hosts.dionysus; prefixLength = net.prefixLength; }
  ];
  networking.defaultGateway = net.gateway;
  networking.nameservers    = [ net.hosts.cerberus "1.1.1.1" ];  # AdGuard primary, Cloudflare fallback

  # ---------------------------------------------------------------------------
  # System packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    curl wget htop git docker-compose
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
  # Docker
  # ---------------------------------------------------------------------------
  virtualisation.docker = {
    enable           = true;
    autoPrune.enable = true;         # weekly container/image cleanup
    # Storage driver — overlay2 is the modern default
    storageDriver    = "overlay2";
    # Ship container logs to Loki on Panoptes for centralized log aggregation.
    # Individual compose services with explicit `logging:` blocks override this.
    daemon.settings = {
      log-driver = "json-file";
      log-opts = {
        max-size = "10m";
        max-file = "3";
        tag = "{{.Name}}";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # NFS mounts from Mnemosyne
  #
  # Adjust the Mnemosyne IP and export paths to match your TrueNAS config.
  # Use x-systemd.automount so the mounts come up on first access and don't
  # block boot if Mnemosyne is briefly unavailable.
  #
  # systemd mount unit names (used in stacks.nix After= deps):
  #   /var/lib/appdata  → var-lib-appdata.mount
  #   /data/media       → data-media.mount
  #   /data/downloads   → data-downloads.mount
  # ---------------------------------------------------------------------------
  fileSystems."/data/media" = {
    device  = "${net.hosts.mnemosyne}:/mnt/media-hdd/media";
    fsType  = "nfs";
    options = [ "nfsvers=4.1" "x-systemd.automount" "noauto" "_netdev" "soft" "timeo=30" ];
  };

  fileSystems."/var/lib/appdata" = {
    device  = "${net.hosts.mnemosyne}:/mnt/apps-ssd/appdata";
    fsType  = "nfs";
    options = [ "nfsvers=4.1" "x-systemd.automount" "noauto" "_netdev" "soft" "timeo=30" ];
  };

  # Local fast SSD path for in-progress downloads (avoid writing incomplete
  # files over NFS). Move completed downloads to /data/media via SABnzbd/Arr.
  # If you'd rather use NFS for downloads too, point this at Mnemosyne.
  fileSystems."/data/downloads" = {
    device  = "/dev/disk/by-label/downloads";   # ← local partition or adjust
    fsType  = "ext4";
    options = [ "defaults" "noatime" "nofail" ];
    # nofail: don't block boot if partition is missing.
    # If no separate partition, remove this block and set DOWNLOADS_DIR in
    # your .env to somewhere on the NFS appdata share.
  };

  # ---------------------------------------------------------------------------
  # deploy user
  #
  # Used by the Action Gateway (on Panoptes) to SSH in and run docker commands.
  # Generate a key on Panoptes:
  #   sudo -u action-gateway ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  # Then paste the public key into authorizedKeys below.
  # ---------------------------------------------------------------------------
  users.users.deploy = {
    isSystemUser = true;
    group        = "docker";     # docker group lets them run `docker` without sudo
    shell        = pkgs.bash;
    home         = "/var/lib/deploy";
    createHome   = true;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOf5Vv46ES5WncCP7jQ4LGgs3LW/OEjmDPm5T3ywB5Rx action-gateway@panoptes"
    ];
  };

  # Narrow sudoers rule: deploy can restart specific containers only.
  # Add more containers here as needed.
  security.sudo.extraRules = [
    {
      users   = [ "deploy" ];
      commands = [
        { command = "/run/current-system/sw/bin/docker restart plex";     options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/docker restart sonarr";   options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/docker restart radarr";   options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/docker restart sabnzbd";  options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  # ---------------------------------------------------------------------------
  # Hardware transcoding (Intel Quick Sync / VA-API)
  # Comment out if Zeus's CPU doesn't support it.
  # ---------------------------------------------------------------------------
  hardware.graphics = {
    enable      = true;
    enable32Bit = true;
  };

  # Grant the Docker daemon (and containers) access to the render node.
  users.groups.render.members  = [ "root" ];
  users.groups.video.members   = [ "root" ];

  # ---------------------------------------------------------------------------
  # Promtail — ships Docker container logs to Loki on Panoptes
  # Reads json-file logs from /var/lib/docker/containers and adds container
  # name labels via Docker metadata.
  # ---------------------------------------------------------------------------
  services.promtail = {
    enable = true;
    configuration = {
      server = {
        http_listen_port = 9080;
        grpc_listen_port = 0;
      };
      positions.filename = "/var/lib/promtail/positions.yaml";
      clients = [{
        url = "http://${net.tailscale.panoptes}:3100/loki/api/v1/push";
      }];
      scrape_configs = [{
        job_name = "docker";
        static_configs = [{
          targets = [ "localhost" ];
          labels = {
            job  = "docker";
            host = "dionysus";
            __path__ = "/var/lib/docker/containers/*/*.log";
          };
        }];
        pipeline_stages = [
          { docker = {}; }
          {
            regex = {
              expression = "^/var/lib/docker/containers/(?P<container_id>[^/]+)/.*$";
              source = "filename";
            };
          }
        ];
      }];
    };
  };

  # ---------------------------------------------------------------------------
  # cAdvisor — per-container resource usage metrics for Prometheus
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers.cadvisor = {
    image = "gcr.io/cadvisor/cadvisor:v0.51.0";
    ports = [ "${net.tailscale.dionysus}:8085:8080" ];
    volumes = [
      "/:/rootfs:ro"
      "/var/run:/var/run:ro"
      "/sys:/sys:ro"
      "/var/lib/docker/:/var/lib/docker:ro"
    ];
    extraOptions = [
      "--privileged"
      "--device=/dev/kmsg"
      "--memory=256m"
    ];
  };

  # ---------------------------------------------------------------------------
  # Prometheus node exporter
  # ---------------------------------------------------------------------------
  services.prometheus.exporters.node = {
    enable            = true;
    port              = 9100;
    enabledCollectors = [ "systemd" "processes" "filesystem" ];
    listenAddress     = "0.0.0.0";
  };

  # ---------------------------------------------------------------------------
  # Firewall
  #
  # Plex (32400) is the only LAN-accessible port — local Plex clients and
  # Plex's relay service both need it on the LAN.
  #
  # Every other service port is Tailscale-only: Traefik on Panoptes routes to
  # them via the Tailscale overlay (using net.tailscale.dionysus as the backend
  # IP in the Traefik file provider config). LAN guests cannot reach any admin
  # UI even if they know the port numbers.
  # ---------------------------------------------------------------------------
  networking.firewall.allowedTCPPorts = [
    32400  # Plex — LAN clients + remote access via Plex relay
  ];
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    9100   # Prometheus node exporter (Panoptes scrapes over Tailscale)
    8085   # cAdvisor (Panoptes scrapes over Tailscale)
    # All service ports — reachable by Traefik on Panoptes via Tailscale
    8989   # Sonarr
    7878   # Radarr
    9696   # Prowlarr
    5055   # Seerr
    8080   # SABnzbd
    8090   # qBittorrent
    43211  # Seanime
    5299   # LazyLibrarian
    8083   # Calibre-Web
    8181   # Shelfmark
    9925   # Mealie
    5006   # Actual Budget
    8282   # Wallos
    7777   # Stirling PDF
    8183   # IT-Tools
    8265   # Tdarr
    8000   # Paperless-ngx
  ];

  # ---------------------------------------------------------------------------
  # NixOS state version
  # ---------------------------------------------------------------------------
  system.stateVersion = "25.11";
}
