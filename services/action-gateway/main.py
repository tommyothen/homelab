"""Action Gateway — FastAPI entrypoint.

Metis (or any trusted internal caller) POSTs to /action/{name}. The gateway
validates the action against the allowlist in actions.yaml, writes a pending
record to the SQLite audit log, and hands off to the Discord bot to notify
the mission-control channel with Approve/Deny buttons.

All approval logic lives in the Discord bot (bot.py); this file only owns the
HTTP API surface and lifecycle management.

Authentication: every endpoint except /health requires a Bearer token matching
ACTION_GATEWAY_TOKEN from the environment. The caller identity recorded in the
audit log is derived from the token, not from request body fields.

Run locally:
    uvicorn main:app --host 127.0.0.1 --port 8080 --reload
"""

import asyncio
import json
import logging
import os
import re
import uuid
from contextlib import asynccontextmanager
from typing import AsyncIterator, Optional

import uvicorn
import yaml
from fastapi import Depends, FastAPI, HTTPException, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from bot import ActionGatewayBot
from db import create_action, get_action_by_id, get_recent_actions, init_db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Config (from environment — see hosts/panoptes/secrets.yaml)
# ---------------------------------------------------------------------------

def _require_env(name: str) -> str:
    """Return an environment variable or exit with a clear error."""
    value = os.environ.get(name)
    if not value:
        logger.error("Required environment variable %s is not set", name)
        raise SystemExit(1)
    return value


DISCORD_TOKEN             = _require_env("DISCORD_TOKEN")
DISCORD_CHANNEL_ID        = int(_require_env("DISCORD_CHANNEL_ID"))
DISCORD_APPROVER_ROLE_ID  = int(_require_env("DISCORD_APPROVER_ROLE_ID"))

# Required: shared secret between Panoptes and Metis (generated at deploy time).
# All non-health endpoints reject requests that don't present this as a
# Bearer token. The .env on Metis must contain the matching value.
ACTION_GATEWAY_TOKEN = _require_env("ACTION_GATEWAY_TOKEN")

ACTIONS_YAML_PATH    = os.environ.get("ACTIONS_YAML_PATH", "actions.yaml")
SCRIPTS_DIR          = os.environ.get("SCRIPTS_DIR", "../../scripts/actions")
DB_PATH              = os.environ.get("DB_PATH", "audit.db")
ACTION_EXPIRY_MINUTES = int(os.environ.get("ACTION_EXPIRY_MINUTES", "15"))


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

_bearer = HTTPBearer(auto_error=True)


def _require_token(
    credentials: HTTPAuthorizationCredentials = Security(_bearer),
) -> str:
    """Validate Bearer token; return the caller identity for audit logging.

    There is currently one valid token (Metis). If the token matches, the
    caller is identified as 'metis'. Requests with missing or wrong tokens
    receive HTTP 401 before touching any business logic.
    """
    if credentials.credentials != ACTION_GATEWAY_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing token.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return "metis"


# ---------------------------------------------------------------------------
# Actions allowlist
# ---------------------------------------------------------------------------

def _load_actions(path: str) -> dict:
    with open(path) as fh:
        config = yaml.safe_load(fh)
    return config.get("actions", {})


actions_config: dict = _load_actions(ACTIONS_YAML_PATH)


# ---------------------------------------------------------------------------
# Discord bot (shared instance, lives for the process lifetime)
# ---------------------------------------------------------------------------

bot = ActionGatewayBot(
    channel_id=DISCORD_CHANNEL_ID,
    approver_role_id=DISCORD_APPROVER_ROLE_ID,
    scripts_dir=SCRIPTS_DIR,
    db_path=DB_PATH,
    expiry_minutes=ACTION_EXPIRY_MINUTES,
)


# ---------------------------------------------------------------------------
# FastAPI app + lifespan
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    await init_db(DB_PATH)
    bot_task = asyncio.create_task(bot.start(DISCORD_TOKEN))
    try:
        yield
    finally:
        bot_task.cancel()
        try:
            await bot_task
        except asyncio.CancelledError:
            pass


app = FastAPI(
    title="Action Gateway",
    description="Controlled execution surface for Metis-requested infrastructure actions.",
    version="0.1.0",
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Response models
# ---------------------------------------------------------------------------

class ActionRequest(BaseModel):
    reason: Optional[str] = None
    context: Optional[dict[str, str]] = None


class ActionResponse(BaseModel):
    id: str
    status: str
    message: str


# ---------------------------------------------------------------------------
# Parameter validation
# ---------------------------------------------------------------------------

def _validate_context(context: dict[str, str], action_config: dict) -> dict[str, str]:
    """Validate context values against the action's params schema.

    Returns the validated env overrides dict. Raises HTTPException on failure.
    """
    params_schema = action_config.get("params")
    if not params_schema:
        if context:
            raise HTTPException(
                status_code=400,
                detail="This action does not accept parameters.",
            )
        return {}

    validated: dict[str, str] = {}
    for param_name, param_def in params_schema.items():
        value = context.get(param_name)
        if value is None:
            if param_def.get("required", False):
                raise HTTPException(
                    status_code=400,
                    detail=f"Missing required parameter: {param_name}",
                )
            continue
        pattern = param_def.get("pattern")
        if pattern and not re.fullmatch(pattern, value):
            raise HTTPException(
                status_code=400,
                detail=f"Parameter {param_name!r} value {value!r} does not match pattern {pattern!r}",
            )
        validated[param_name] = value

    unknown = set(context.keys()) - set(params_schema.keys())
    if unknown:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown parameters: {', '.join(sorted(unknown))}",
        )
    return validated


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

def _log_task_error(task: asyncio.Task) -> None:
    if task.cancelled() or task.exception() is None:
        return
    logger.error("Failed to post action to Discord: %s", task.exception())


@app.post("/action/{name}", response_model=ActionResponse)
async def request_action(
    name: str,
    body: ActionRequest | None = None,
    caller: str = Depends(_require_token),
) -> ActionResponse:
    """Queue an action for human approval via Discord."""
    if name not in actions_config:
        logger.warning("Unknown action %r requested by %s", name, caller)
        raise HTTPException(
            status_code=400,
            detail="Unknown action.",
        )

    action_cfg = actions_config[name]
    reason = body.reason if body else None
    context = body.context if body else None

    env_overrides: dict[str, str] = {}
    if context:
        env_overrides = _validate_context(context, action_cfg)

    action_id = str(uuid.uuid4())
    await create_action(
        DB_PATH, action_id, name, caller,
        reason=reason,
        context=json.dumps(context) if context else None,
    )

    task = asyncio.create_task(
        bot.post_action_request(
            action_id, name, action_cfg, caller,
            reason=reason,
            context=context,
            env_overrides=env_overrides,
        )
    )
    task.add_done_callback(_log_task_error)

    logger.info("Queued action %r (id=%s) requested by %s", name, action_id, caller)
    return ActionResponse(
        id=action_id,
        status="pending",
        message=f"Action {name!r} queued for approval in Discord.",
    )


@app.get("/action/{action_id}")
async def get_action_status(
    action_id: str,
    caller: str = Depends(_require_token),
) -> dict:
    """Return the full record for a single action by ID."""
    record = await get_action_by_id(DB_PATH, action_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Action not found.")
    return record


@app.get("/actions")
async def list_actions(caller: str = Depends(_require_token)) -> dict:
    """List all available (allowlisted) actions."""
    return {
        "actions": {
            name: {
                "description": cfg.get("description", ""),
                "script":      cfg.get("script", ""),
                "timeout":     cfg.get("timeout", 60),
                **({"params": cfg["params"]} if "params" in cfg else {}),
            }
            for name, cfg in actions_config.items()
        }
    }


@app.get("/log")
async def get_log(
    limit: int = 50,
    caller: str = Depends(_require_token),
) -> dict:
    """Return recent audit log entries."""
    if limit > 200:
        limit = 200
    records = await get_recent_actions(DB_PATH, limit)
    return {"log": records}


@app.get("/health")
async def health() -> dict:
    """Liveness check — intentionally unauthenticated for uptime monitoring."""
    return {"status": "ok", "bot_ready": bot._ready_event.is_set()}


# ---------------------------------------------------------------------------
# Direct run (dev only — production uses systemd + uvicorn CLI)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run("main:app", host="127.0.0.1", port=8080, log_level="info")
