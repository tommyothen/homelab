#!/usr/bin/env bash
set -euo pipefail

# Fresh NixOS bootstrap helper.
#
# Usage (on fresh host):
#   curl -fsSL http://192.168.5.225:8000/scripts/bootstrap-fresh-nixos.sh | bash
#
# Optional env vars:
#   SERVER_BASE=http://192.168.5.225:8000
#   REPO_URL=http://192.168.5.225:8000/homelab.git
#   TARGET_DIR=/root/homelab

SERVER_BASE="${SERVER_BASE:-http://192.168.5.225:8000}"
REPO_URL="${REPO_URL:-${SERVER_BASE}/homelab.git}"
TARGET_DIR="${TARGET_DIR:-/root/homelab}"
BOOTSTRAP_CONFIG="/etc/nixos/bootstrap.nix"

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required but not found."
  exit 1
fi

echo "[1/5] Cloning repo from ${REPO_URL}"
sudo rm -rf "${TARGET_DIR}"
sudo nix --extra-experimental-features "nix-command flakes" shell nixpkgs#git -c \
  git clone "${REPO_URL}" "${TARGET_DIR}"

if [ ! -f "${TARGET_DIR}/flake.nix" ]; then
  echo "Clone succeeded but ${TARGET_DIR}/flake.nix was not found."
  echo "Check REPO_URL and try again."
  exit 1
fi

echo "[2/5] Writing ${BOOTSTRAP_CONFIG}"
sudo tee "${BOOTSTRAP_CONFIG}" >/dev/null <<'EOF'
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    (builtins.getFlake "path:/root/homelab").nixosModules.bootstrap
  ];
}
EOF

echo "[3/5] Applying bootstrap config"
sudo nixos-rebuild switch \
  --extra-experimental-features "nix-command flakes" \
  -I nixos-config="${BOOTSTRAP_CONFIG}"

echo "[4/5] Bringing up Tailscale"
if ! sudo tailscale up; then
  echo "tailscale up did not complete automatically. Run it manually after login/auth."
fi

echo "[5/5] Printing host age key for sops"
if command -v sops-host-age >/dev/null 2>&1; then
  sops-host-age
else
  echo "sops-host-age not found. Re-open shell and run: sops-host-age"
fi

echo
echo "Bootstrap complete."
echo "Next steps:"
echo "1) Add printed age1 key to .sops.yaml"
echo "2) Encrypt hosts/<host>/secrets.yaml"
echo "3) Switch to your real host config: sudo nixos-rebuild switch --flake path:/root/homelab#<host>"
