# hosts/panoptes/hardware-configuration.nix
#
# Proxmox QEMU/KVM VM on Zeus (x86_64).
# Kernel modules mirrored from Dionysus (identical VM setup).
# UUIDs must be updated after reinstall — run: nixos-generate-config --show-hardware-config

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [ "uhci_hcd" "ehci_pci" "ahci" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules           = [];
  boot.kernelModules                  = [];
  boot.extraModulePackages            = [];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/eab49f76-1d0f-4372-a239-a5cafef885d4";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/640B-345D";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
