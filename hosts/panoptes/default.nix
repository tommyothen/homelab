# hosts/panoptes/default.nix
#
# Panoptes — NixOS VM on Zeus (x86_64)
# Role: observability + alerting + Action Gateway
#
# Runs:
#   - Prometheus (native NixOS module)
#   - Grafana    (native NixOS module)
#   - Alertmanager (native — routes to OpenClaw webhook on Metis)
#   - Gatus      (Docker Compose — declarative uptime monitoring)
#   - Action Gateway (see ./services/action-gateway.nix)

{ config, pkgs, lib, net, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./services/action-gateway.nix
    ./services/mcp-homelab.nix
    ./services/stacks.nix
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------
  networking.hostName = "panoptes";

  networking.interfaces.ens18.ipv4.addresses = [
    { address = net.hosts.panoptes; prefixLength = net.prefixLength; }
  ];
  networking.defaultGateway = net.gateway;
  networking.nameservers    = [ net.hosts.cerberus "1.1.1.1" ];  # AdGuard primary, Cloudflare fallback

  # ---------------------------------------------------------------------------
  # System packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    curl wget htop git prometheus-alertmanager
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
  # NFS mount for appdata (action gateway data, service appdata, etc.)
  # ---------------------------------------------------------------------------
  fileSystems."/var/lib/appdata" = {
    device  = "${net.hosts.mnemosyne}:/mnt/apps-ssd/appdata";
    fsType  = "nfs";
    options = [ "nfsvers=4.1" "x-systemd.automount" "noauto" "_netdev" "soft" "timeo=30" ];
  };

  # ---------------------------------------------------------------------------
  # Docker (for Docker Compose stacks on Panoptes)
  # ---------------------------------------------------------------------------
  virtualisation.docker.enable     = true;

  # ---------------------------------------------------------------------------
  # Promtail — ships Docker container logs to Loki (local)
  #
  # The NixOS promtail module uses PrivateTmp + PrivateDevices by default;
  # in Proxmox KVM VMs the mount-namespace setup for ExecStartPre can fail
  # with status=226/NAMESPACE. Disable the offending setting at module level
  # so the pre-start (state dir creation) runs without namespace isolation —
  # the main promtail process still runs under the DynamicUser sandbox.
  # ---------------------------------------------------------------------------
  systemd.services.promtail.serviceConfig.PrivateTmp = lib.mkForce false;

  services.promtail = {
    enable = true;
    configuration = {
      server = {
        http_listen_port = 9080;
        grpc_listen_port = 0;
      };
      positions.filename = "/var/lib/promtail/positions.yaml";
      clients = [{
        url = "http://localhost:3100/loki/api/v1/push";
      }];
      scrape_configs = [
        {
          job_name = "docker";
          static_configs = [{
            targets = [ "localhost" ];
            labels = {
              job  = "docker";
              host = "panoptes";
              __path__ = "/var/lib/docker/containers/*/*.log";
            };
          }];
          pipeline_stages = [
            { docker = {}; }
            {
              regex.expression = "^/var/lib/docker/containers/(?P<container_id>[^/]+)/.*$";
              source = "filename";
            }
          ];
        }
        {
          job_name = "journal";
          journal = {
            max_age = "12h";
            labels = {
              job  = "systemd-journal";
              host = "panoptes";
            };
          };
          relabel_configs = [{
            source_labels = [ "__journal__systemd_unit" ];
            target_label  = "unit";
          }];
        }
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # cAdvisor — per-container resource usage metrics for Prometheus
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers.containers.cadvisor = {
    image = "gcr.io/cadvisor/cadvisor:v0.51.0";
    ports = [ "127.0.0.1:8085:8080" ];
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
  # Loki — centralized log aggregation
  # Docker containers on Dionysus and Panoptes ship logs here via the Loki
  # Docker log driver. Grafana queries Loki for log search/correlation.
  # ---------------------------------------------------------------------------
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server = {
        http_listen_port = 3100;
        http_listen_address = "0.0.0.0";
      };
      common = {
        path_prefix = "/var/lib/loki";
        storage.filesystem.chunks_directory = "/var/lib/loki/chunks";
        storage.filesystem.rules_directory  = "/var/lib/loki/rules";
        ring = {
          instance_addr = "127.0.0.1";
          kvstore.store  = "inmemory";
        };
      };
      schema_config.configs = [{
        from         = "2024-01-01";
        store        = "tsdb";
        object_store = "filesystem";
        schema       = "v13";
        index = {
          prefix = "index_";
          period = "24h";
        };
      }];
      limits_config = {
        retention_period = "30d";
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
      };
      compactor = {
        working_directory     = "/var/lib/loki/compactor";
        compaction_interval   = "10m";
        retention_enabled     = true;
        retention_delete_delay = "2h";
        delete_request_store  = "filesystem";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Prometheus
  # ---------------------------------------------------------------------------
  services.prometheus = {
    enable = true;
    port   = 9090;

    # Retention: 30 days.  Adjust for your disk size.
    extraFlags = [ "--storage.tsdb.retention.time=30d" ];

    scrapeConfigs = [
      {
        job_name       = "node";
        scrape_interval = "30s";
        static_configs = [{
          targets = [
            "localhost:9100"                           # panoptes itself
            "${net.tailscale.dionysus}:9100"           # media VM (tailscale0)
            "${net.tailscale.cerberus}:9100"           # gateway Pi (tailscale0)
            "${net.tailscale.metis}:9100"              # AI ops Pi (tailscale0)
            "${net.tailscale.tartarus}:9100"           # OCI backup server (tailscale0)
            "${net.tailscale.hephaestus}:9100"         # OCI game server (tailscale0)
          ];
        }];
      }
      {
        job_name        = "cadvisor";
        scrape_interval = "30s";
        static_configs = [{
          targets = [
            "localhost:8085"                                 # panoptes
            "${net.tailscale.dionysus}:8085"                 # dionysus
          ];
        }];
      }
      {
        job_name        = "prometheus";
        scrape_interval = "60s";
        static_configs  = [{ targets = [ "localhost:9090" ]; }];
      }
      {
        job_name        = "grafana";
        scrape_interval = "60s";
        static_configs  = [{ targets = [ "localhost:3000" ]; }];
      }
      {
        # Speedtest Tracker — metrics at /api/prometheus.
        # The container exposes port 8889 on host loopback (see compose).
        job_name        = "speedtest";
        scrape_interval = "360m";   # align with SPEEDTEST_SCHEDULE (every 6h)
        metrics_path    = "/api/prometheus";
        static_configs  = [{ targets = [ "localhost:8889" ]; }];
      }
      {
        # Proxmox VE — via prometheus-pve-exporter (see compose).
        # The exporter proxies to Zeus's Proxmox API using the configured token.
        # Relabelling routes all scrapes through the exporter on localhost:9221.
        job_name        = "pve";
        scrape_interval = "60s";
        metrics_path    = "/pve";
        params          = { module = [ "default" ]; };
        static_configs  = [{ targets = [ "${net.hosts.zeus}" ]; }];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label  = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label  = "instance";
          }
          {
            target_label = "__address__";
            replacement  = "localhost:9221";
          }
        ];
      }
    ];

    # Alertmanager integration (see alertmanager block below)
    alertmanagers = [{
      static_configs = [{ targets = [ "localhost:9093" ]; }];
    }];

    # Alert rules — add more as needed
    rules = [''
      groups:
        - name: homelab
          rules:
            - alert: InstanceDown
              expr: up == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "{{ $labels.instance }} is down"
                description: "{{ $labels.instance }} has been unreachable for >5 minutes."

            - alert: HighDiskUsage
              expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.10
              for: 10m
              labels:
                severity: warning
              annotations:
                summary: "Low disk space on {{ $labels.instance }}"
                description: "Root filesystem is <10% free."
    ''];
  };

  # ---------------------------------------------------------------------------
  # Prometheus node exporter (self-monitoring)
  # ---------------------------------------------------------------------------
  services.prometheus.exporters.node = {
    enable            = true;
    port              = 9100;
    enabledCollectors = [ "systemd" "processes" "filesystem" ];
    listenAddress     = "127.0.0.1";  # Only scraped locally by Prometheus on this host
  };

  # ---------------------------------------------------------------------------
  # Alertmanager — routes to OpenClaw webhook on Metis
  #
  # Alertmanager's NixOS module runs envsubst on the configuration, so
  # $OPENCLAW_HOOKS_TOKEN is expanded from the EnvironmentFile below.
  # ---------------------------------------------------------------------------
  sops.secrets.alertmanager_hooks_token = {
    sopsFile = ./secrets.yaml;
    owner    = "root";
    mode     = "0400";
  };

  systemd.services.alertmanager.serviceConfig.EnvironmentFile =
    config.sops.secrets.alertmanager_hooks_token.path;

  services.prometheus.alertmanager = {
    enable = true;
    port   = 9093;

    configuration = {
      global = {
        resolve_timeout = "5m";
      };
      route = {
        receiver       = "openclaw";
        group_wait     = "30s";
        group_interval = "5m";
        repeat_interval = "4h";
      };
      receivers = [{
        name = "openclaw";
        webhook_configs = [{
          url           = "http://${net.tailscale.metis}:18789/hooks/alertmanager";
          send_resolved = true;
          http_config = {
            authorization = {
              type        = "Bearer";
              credentials = "$OPENCLAW_HOOKS_TOKEN";
            };
          };
        }];
      }];
    };
  };

  # ---------------------------------------------------------------------------
  # Grafana
  # ---------------------------------------------------------------------------
  services.grafana = {
    enable = true;

    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
        domain    = "grafana.${net.domain}";
      };
      security = {
        admin_user     = "admin";
        # Password injected via sops-nix EnvironmentFile (see services/stacks.nix).
        admin_password = "$__env{GF_SECURITY_ADMIN_PASSWORD}";
      };
      analytics.reporting_enabled = false;
    };

    provision = {
      enable = true;

      datasources.settings = {
        datasources = [
          {
            name      = "Prometheus";
            type      = "prometheus";
            url       = "http://localhost:9090";
            isDefault = true;
            access    = "proxy";
          }
          {
            name   = "Loki";
            type   = "loki";
            url    = "http://localhost:3100";
            access = "proxy";
          }
        ];
      };

      # Drop dashboard JSON files in /etc/grafana/dashboards/ and they'll
      # be auto-imported. Or use Grafana's UI and export from there.
      dashboards.settings = {
        providers = [
          {
            name    = "default";
            orgId   = 1;
            type    = "file";
            options = { path = "/etc/grafana/dashboards"; };
          }
        ];
      };
    };
  };

  # Create the dashboards directory so Grafana doesn't error on startup.
  systemd.tmpfiles.rules = [
    "d /etc/grafana/dashboards 0755 grafana grafana -"
  ];

  # ---------------------------------------------------------------------------
  # Firewall
  #
  # Traefik runs split ingress:
  #   - Tailscale interface: admin/control-plane routes
  #   - LAN interface: selected home-facing routes (home, plex, seerr)
  #
  # Admin UIs remain Tailscale-only by DNS + Traefik router entrypoint binding.
  #
  # Traefik (80/443): open on tailscale0 and on the LAN interface (ens18).
  # LAN access is limited to routers explicitly bound to lanwebsecure.
  #
  # br-panoptes: the named Docker bridge (driver_opts set in docker-compose.yml).
  # We open Grafana/Prometheus to it so the Traefik container (which lives on
  # that bridge) can proxy to these NixOS-native services without needing them
  # exposed to any external interface.
  #
  # Action Gateway (8080) is Tailscale-only, configured in ./services/action-gateway.nix.
  # ---------------------------------------------------------------------------
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    80     # Traefik HTTP  (redirects to 443)
    443    # Traefik HTTPS
    9090   # Prometheus
    9093   # Alertmanager
    3000   # Grafana
    3100   # Loki (log ingestion from other hosts)
    9100   # Node exporter
  ];

  networking.firewall.interfaces.ens18.allowedTCPPorts = [
    80     # Traefik LAN HTTP  (redirects to LAN HTTPS)
    443    # Traefik LAN HTTPS (only routers on lanwebsecure)
  ];

  # Allow the Traefik Docker container to reach Grafana and Prometheus on this
  # host. Traffic arrives on the br-panoptes bridge interface, not tailscale0.
  networking.firewall.interfaces."br-panoptes".allowedTCPPorts = [
    3000   # Grafana
    3100   # Loki
    9090   # Prometheus
    9093   # Alertmanager
  ];

  # ---------------------------------------------------------------------------
  # NixOS state version
  # ---------------------------------------------------------------------------
  system.stateVersion = "25.11";
}
