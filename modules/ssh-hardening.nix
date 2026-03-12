# modules/ssh-hardening.nix
#
# Baseline SSH hardening applied to every host.
# Keys only — no password auth, no root login.

{ config, ... }:

{
  # Open SSH on the Tailscale interface so management access works now that
  # tailscale0 is no longer unconditionally trusted in tailscale.nix.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];

  services.openssh = {
    enable = true;

    settings = {
      PasswordAuthentication         = false;
      PermitRootLogin                = "no";
      KbdInteractiveAuthentication   = false;
      X11Forwarding                  = false;
      # Limit auth attempts before disconnect
      MaxAuthTries = 3;
      # Disable agent forwarding — not needed in this infra
      AllowAgentForwarding = false;
      # Drop idle sessions after 5 min of silence (2 × 150s)
      ClientAliveInterval  = 150;
      ClientAliveCountMax  = 2;
    };

    # Modern cipher/MAC/kex suite only.
    extraConfig = ''
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
      MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
      KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,sntrup761x25519-sha512@openssh.com
    '';
  };
}
