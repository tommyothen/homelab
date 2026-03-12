# modules/firewall-baseline.nix
#
# Minimal firewall baseline: enable nftables, allow SSH.
# Each host's own config opens the ports it needs beyond SSH.

{ ... }:

{
  networking.firewall = {
    enable = true;
    # SSH open everywhere; everything else is per-host.
    allowedTCPPorts = [ 22 ];
  };

  # Prefer nftables over the legacy iptables backend.
  networking.nftables.enable = true;
}
