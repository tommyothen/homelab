# Pelican Panel Stack

Compose stack for the Pelican Panel (Pterodactyl successor) and its backing services.

## Purpose

- Provides web administration for game servers managed by Wings.
- Exposed through Panoptes Traefik as `panel.0x21.uk` over Tailscale.

## Startup

Manage via the Hephaestus systemd unit:

```bash
sudo systemctl start pterodactyl
```

After Panel is online, generate node config and place it on Hephaestus at `/etc/pterodactyl/config.yml` for Wings.
