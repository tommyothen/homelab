# Dionysus Stacks

Application stacks that run on the Dionysus media VM.

## Stack groups

- `media-core/`: Plex and core Arr/Usenet services.
- `media-vpn/`: VPN-routed torrent fallback path.
- `media-extras/`: companion media tools (for example Tdarr, Seanime).
- `books/`: ebook acquisition and library serving pipeline.
- `personal/`: self-hosted personal productivity apps.
- `paperless/`: document OCR and indexing pipeline.

## Operations

- Preferred: manage with systemd units on Dionysus (`sudo systemctl start media-core media-vpn media-extras books personal paperless`).
- Single stack: `sudo systemctl start <stack-name>`.
- Direct `docker compose` usage is for debugging/recovery, not the default workflow.
