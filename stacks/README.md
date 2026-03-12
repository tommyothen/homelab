# Compose Stacks

Docker Compose workloads grouped by host and function.

## Layout

- `stacks/dionysus/`: media, books, personal tools, and document workflows.
- `stacks/panoptes/`: ingress, auth, uptime checks, ops dashboard services, and homelab map.
- `stacks/hephaestus/`: game management stack (Pelican Panel + Infrared proxy).

## Usage

Use host systemd units as the default lifecycle manager:

- Dionysus stacks: `sudo systemctl start media-core media-vpn media-extras books personal paperless`
- Panoptes ingress stack: `sudo systemctl start ingress`
- Hephaestus panel stack: `sudo systemctl start pterodactyl infrared`

Direct `docker compose` commands are reserved for troubleshooting and recovery.
