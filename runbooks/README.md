# Runbooks

Step-by-step recovery and operations guides.

## Files

- `zeus-recovery.md`: Proxmox/VM recovery and rebuild sequence.
- `offsite-backup.md`: Tartarus restic backup setup and restore flow.
- `fresh-start-local-first.md`: full greenfield bring-up order (local first, OCI second).
- `proxmox-nixos-vm-bootstrap.md`: clean install/bootstrap flow for new NixOS VMs on Proxmox.
- `oci-nixos-deploy.md`: build NixOS ARM64 image, Terraform deploy to OCI, bootstrap Tartarus + Hephaestus.
- `pi-bootstrap.md`: build NixOS SD card image, flash via Pi Imager, bootstrap Cerberus + Metis.

Keep this directory procedural and incident-focused.
