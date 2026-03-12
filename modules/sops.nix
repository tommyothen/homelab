# modules/sops.nix
#
# sops-nix integration for all hosts.
#
# Secrets are encrypted at rest in the git repo and decrypted automatically
# at NixOS activation time. No manual secret-copy step on rebuild.
#
# Key strategy: age keys are derived from each host's SSH ed25519 host key.
# That key is auto-generated on first boot and lives at:
#   /etc/ssh/ssh_host_ed25519_key
# No separate age key management needed.
#
# ---------------------------------------------------------------------------
# SETUP INSTRUCTIONS (one-time, per host)
# ---------------------------------------------------------------------------
#
# 1. Get the age public key for a host (after first boot):
#
#      nix shell nixpkgs#ssh-to-age -c \
#        ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
#
#    On fresh hosts where nix-command/flakes are not enabled yet:
#
#      nix --extra-experimental-features "nix-command flakes" \
#        shell nixpkgs#ssh-to-age -c \
#        ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
#
#    Or remotely:
#
#      ssh root@<host> cat /etc/ssh/ssh_host_ed25519_key.pub \
#        | nix shell nixpkgs#ssh-to-age -c ssh-to-age
#
# 2. Paste the output (age1...) into .sops.yaml under the host's key.
#
# 3. Also add your admin workstation's age key to .sops.yaml so you can
#    edit secrets from your laptop:
#
#      age-keygen -o ~/.config/sops/age/keys.txt
#      age-keygen -y ~/.config/sops/age/keys.txt  # print public key
#
# 4. Create an encrypted secrets file for a host:
#
#      nix run nixpkgs#sops -- hosts/<host>/secrets.yaml
#
# ---------------------------------------------------------------------------
# USAGE IN A HOST CONFIG
# ---------------------------------------------------------------------------
#
#   sops.secrets.my_secret = {
#     sopsFile = ./secrets.yaml;   # path relative to host's default.nix
#   };
#
# Access at runtime: config.sops.secrets.my_secret.path
# The decrypted content is a file in /run/secrets/ readable by root by default.
#
# To make a secret readable by a service user:
#
#   sops.secrets.my_secret = {
#     sopsFile = ./secrets.yaml;
#     owner    = "myservice";
#     group    = "myservice";
#     mode     = "0440";
#   };
#
# ---------------------------------------------------------------------------

{ pkgs, ... }:

{
  # Tools for managing sops secrets — available on every host.
  environment.systemPackages = with pkgs; [ ssh-to-age sops age ];

  # Derive the age key from the host's SSH ed25519 host key.
  # This key is generated automatically on first boot and persists across rebuilds.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Where sops-nix writes decrypted secrets at activation time.
  # Default is /run/secrets — ephemeral, never written to disk unencrypted.
  sops.defaultSopsFormat = "yaml";
}
