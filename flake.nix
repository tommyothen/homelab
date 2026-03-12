{
  description = "Homelab NixOS configurations — Cerberus, Dionysus, Panoptes, Metis, Tartarus, Hephaestus";

  inputs = {
    # Stable channel — pin this and update deliberately.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # sops-nix — encrypted secrets decrypted at activation time.
    # Keys are derived from each host's SSH ed25519 host key (auto-generated on boot).
    # See modules/sops.nix and .sops.yaml for setup instructions.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # home-manager is optional; uncomment if you want per-user dotfiles.
    # home-manager = {
    #   url = "github:nix-community/home-manager/release-25.11";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };

  outputs = { self, nixpkgs, sops-nix, ... }:
    let
      lib = nixpkgs.lib;

      # ---------------------------------------------------------------------------
      # Network topology — change these when your network changes.
      # Every host receives `net` via specialArgs.
      # ---------------------------------------------------------------------------
      net = {
        domain       = "0x21.uk";
        prefixLength = 22;
        gateway      = "192.168.4.1";

        # LAN hosts (static IPs — reserve in router DHCP)
        hosts = {
          cerberus  = "192.168.4.119";  # DNS / AdGuard (Pi 4B)
          metis     = "192.168.4.248";  # AI ops Pi (Pi 4B)
          hestia    = "192.168.5.180";  # Home Assistant Yellow
          dionysus  = "192.168.5.233";  # media VM (Zeus)
          panoptes  = "192.168.5.236";  # observability VM (Zeus)
          mnemosyne = "192.168.5.228";  # TrueNAS NFS server (Zeus)
          zeus      = "192.168.4.243";  # Proxmox host IP
        };

        # OCI ARM free tier — two VMs, kept strictly separate.
        # Tartarus: 1 OCPU / 6 GB RAM / 50 GB  — off-site backup target only
        # Hephaestus: 3 OCPU / 18 GB RAM / 150 GB — game servers (Minecraft + Pterodactyl)
        # Never run game servers on the same instance as backup storage.
        external = {
          tartarus   = "141.147.109.212";
          hephaestus = "132.226.134.126";
        };

        # Tailscale IPs — run `scripts/tailscale-ips.sh` to populate all at once.
        # Used to route admin traffic exclusively over the Tailscale overlay.
        tailscale = {
          cerberus   = "100.126.162.21";
          metis      = "100.105.12.14";
          dionysus   = "100.72.127.74";
          panoptes   = "100.99.237.72";
          tartarus   = "100.85.227.117";
          hephaestus = "100.71.202.37";
          asclepius  = "100.80.1.87";
        };
      };

      # Overlay: vendored OpenClaw package (used only by Metis).
      openclawOverlay = final: prev: {
        openclaw = final.callPackage ./packages/openclaw { };
      };

      # Shared modules imported by every host.
      commonModules = [
        ./modules/ssh-hardening.nix
        ./modules/tailscale.nix
        ./modules/firewall-baseline.nix
        ./modules/sops.nix
        sops-nix.nixosModules.sops
      ];
    in
    {
      nixosConfigurations = {

        # --- Raspberry Pi 4B — network gateway, AdGuard, Tailscale --------
        cerberus = lib.nixosSystem {
          system      = "aarch64-linux";
          specialArgs = { inherit net; };
          modules     = commonModules ++ [ ./hosts/cerberus ];
        };

        # --- NixOS VM on Zeus — Plex + Arr suite + Seerr + SABnzbd --------
        dionysus = lib.nixosSystem {
          system      = "x86_64-linux";
          specialArgs = { inherit net; };
          modules     = commonModules ++ [ ./hosts/dionysus ];
        };

        # --- NixOS VM on Zeus — Prometheus, Grafana, Action Gateway --------
        panoptes = lib.nixosSystem {
          system      = "x86_64-linux";
          specialArgs = { inherit net; };
          modules     = commonModules ++ [ ./hosts/panoptes ];
        };

        # --- Raspberry Pi 4B — AI co-DevOps node (OpenClaw / Metis) -------
        metis = lib.nixosSystem {
          system      = "aarch64-linux";
          specialArgs = { inherit net; };
          modules     = commonModules ++ [
            { nixpkgs.overlays = [ openclawOverlay ]; }
            ./hosts/metis
          ];
        };

        # --- OCI ARM (aarch64) — off-site backup target --------------------
        # 1 OCPU / 6 GB RAM / 50 GB storage
        # Receives encrypted restic snapshots from Mnemosyne over SSH.
        # See runbooks/offsite-backup.md for setup.
        tartarus = lib.nixosSystem {
          system      = "aarch64-linux";
          specialArgs = { inherit net; };
          modules     = commonModules ++ [ ./hosts/tartarus ];
        };

        # --- OCI ARM (aarch64) — game servers (Minecraft + Pterodactyl) ----
        # 3 OCPU / 18 GB RAM / 150 GB storage
        # Pterodactyl Wings manages game server containers via Docker.
        # Panel (web UI) accessible over Tailscale via Traefik on Panoptes.
        hephaestus = lib.nixosSystem {
          system      = "aarch64-linux";
          specialArgs = { inherit net; };
          modules     = commonModules ++ [ ./hosts/hephaestus ];
        };

      };
    };
}
