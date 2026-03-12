# bootstrap/oci/flake.nix
#
# Builds a NixOS ARM64 qcow2 image for OCI deployment.
# This is a one-shot bootstrap image — after first boot, instances are
# handed off to the main homelab flake (flake.nix in repo root).
#
# Build:  nix build .#packages.aarch64-linux.default
# Output: result/nixos-image-oci-*.qcow2
{
  description = "NixOS OCI ARM64 bootstrap image";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.oci-base = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        # OCI image builder — provides disk layout, boot config, cloud-init
        "${nixpkgs}/nixos/modules/virtualisation/oci-image.nix"

        # Bootstrap configuration (adapted for OCI)
        ./configuration.nix
      ];
    };

    # The image derivation — `nix build .#` produces result/nixos.qcow2
    packages.aarch64-linux.default =
      self.nixosConfigurations.oci-base.config.system.build.OCIImage;
  };
}
