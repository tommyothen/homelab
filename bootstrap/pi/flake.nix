# bootstrap/pi/flake.nix
#
# Builds NixOS aarch64 SD card images for Raspberry Pi 4B hosts.
# This is a one-shot bootstrap image — after first boot, hand off to the
# main homelab flake (flake.nix in repo root).
#
# Build a specific host:
#   nix build .#cerberus   → result/sd-image/nixos-sd-image-*-cerberus.img.zst
#   nix build .#metis      → result/sd-image/nixos-sd-image-*-metis.img.zst
#
# Cross-compilation from x86 WSL requires QEMU binfmt (already set up for OCI):
#   sudo systemctl restart systemd-binfmt
#
# Flash via Raspberry Pi Imager: use "Custom image" and select the .img.zst file.
{
  description = "NixOS Raspberry Pi 4B bootstrap SD images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      buildPiImage = hostname: nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          ./configuration.nix
          { networking.hostName = hostname; }
        ];
      };
    in
    {
      packages.aarch64-linux = {
        cerberus = (buildPiImage "cerberus").config.system.build.sdImage;
        metis    = (buildPiImage "metis").config.system.build.sdImage;
      };
    };
}
