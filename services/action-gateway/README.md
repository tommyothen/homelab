# Action Gateway Service

FastAPI service that enforces human approval before operational scripts run.

## Purpose

- Accepts action requests from trusted clients (for example, Metis).
- Validates action names against `actions.yaml` allowlist.
- Supports parameterized actions with validated context and reason fields.
- Sends Discord approval prompts (with reason/parameters visible) and only executes scripts after approval.
- Stores audit history in SQLite.
- Provides a status endpoint so callers can poll action outcomes.

## API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/action/{name}` | Request an action. Accepts optional JSON body: `{"reason": "...", "context": {"PARAM": "value"}}` |
| `GET` | `/action/{action_id}` | Get full status of a specific action by UUID |
| `GET` | `/actions` | List all allowlisted actions (with params schema if defined) |
| `GET` | `/log` | Recent audit log entries (limit 200) |
| `GET` | `/health` | Liveness check (unauthenticated, for uptime monitoring) |

All endpoints except `/health` require a `Bearer` token matching `ACTION_GATEWAY_TOKEN`.

## Parameterized actions

Actions can define a `params` schema in `actions.yaml`. When a caller includes `context` in the POST body, values are validated against the schema (required fields, regex patterns) and passed to the script as environment variables. Unknown or invalid parameters are rejected with HTTP 400.

Example `actions.yaml` entry:
```yaml
restart-container:
  script: restart-container.sh
  timeout: 60
  params:
    CONTAINER_NAME:
      required: true
      pattern: "^[a-zA-Z0-9_-]+$"
    TARGET_HOST:
      required: true
      pattern: "^(dionysus|panoptes)$"
```

Example request:
```bash
curl -X POST http://panoptes:8080/action/restart-container \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reason": "Plex is unresponsive", "context": {"CONTAINER_NAME": "plex", "TARGET_HOST": "dionysus"}}'
```

## Files

- `main.py`: API server, route definitions, and parameter validation logic.
- `bot.py`: Discord bot event loop, approval interactions, reason/context display in embeds.
- `executor.py`: script execution, output capture, and environment override injection.
- `db.py`: persistence layer for action request states (including reason and context).
- `actions.yaml`: allowed action registry, script mapping, and optional params schema.
- `requirements.txt`: Python dependency set.

## Operational notes

- Keep scripts in `scripts/actions/` idempotent where possible.
- Any new action must be added to both `actions.yaml` and the script directory.
- Parameterized actions must define a `params` schema — the gateway will not pass arbitrary env vars.
- Treat this directory as a security boundary: least privilege, explicit allowlists.
