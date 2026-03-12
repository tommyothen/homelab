# modules/tailscale.nix
#
# Enable Tailscale on every host and trust the tailscale0 interface so that
# Tailscale-sourced traffic bypasses the host firewall.
#
# Initial auth: run `sudo tailscale up --auth-key=<key>` after first boot,
# or set services.tailscale.authKeyFile to a path containing the key so
# NixOS activates it automatically.

{ config, pkgs, ... }:

{
  services.tailscale = {
    enable = true;
    # Uncomment and point to a file containing a one-time auth key for
    # automated bring-up (e.g. on the appdata NFS share):
    # authKeyFile = "/var/lib/tailscale-authkey";
  };

  environment.systemPackages = [ pkgs.tailscale ];

  networking.firewall = {
    # Do NOT set trustedInterfaces here — that would bypass the host firewall
    # for all Tailscale peers on every port. Instead, each host module opens
    # only the ports it needs on tailscale0 via:
    #   networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ ... ];
    #
    # Tailscale ACLs in the admin console are the right place to restrict
    # which peers can reach which hosts at the network level.
    #
    # Allow the Tailscale DERP/direct UDP port.
    allowedUDPPorts = [ config.services.tailscale.port ];
  };
}
