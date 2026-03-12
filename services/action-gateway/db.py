"""SQLite audit log helpers for the Action Gateway."""

import aiosqlite
from datetime import datetime
from typing import Optional


async def init_db(db_path: str) -> None:
    async with aiosqlite.connect(db_path) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS actions (
                id          TEXT PRIMARY KEY,
                action_name TEXT NOT NULL,
                requested_at TEXT NOT NULL,
                requested_by TEXT NOT NULL,
                status       TEXT NOT NULL DEFAULT 'pending',
                actioned_by  TEXT,
                actioned_at  TEXT,
                result       TEXT,
                reason       TEXT,
                context      TEXT
            )
        """)
        await db.commit()


async def create_action(
    db_path: str,
    id: str,
    action_name: str,
    requested_by: str,
    reason: Optional[str] = None,
    context: Optional[str] = None,
) -> dict:
    now = datetime.utcnow().isoformat()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT INTO actions (id, action_name, requested_at, requested_by, status, reason, context) "
            "VALUES (?, ?, ?, ?, 'pending', ?, ?)",
            (id, action_name, now, requested_by, reason, context),
        )
        await db.commit()
    return {
        "id": id,
        "action_name": action_name,
        "requested_at": now,
        "requested_by": requested_by,
        "status": "pending",
        "reason": reason,
        "context": context,
    }


async def update_action(
    db_path: str,
    id: str,
    status: str,
    actioned_by: Optional[str] = None,
    result: Optional[str] = None,
) -> None:
    now = datetime.utcnow().isoformat()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "UPDATE actions SET status=?, actioned_by=?, actioned_at=?, result=? WHERE id=?",
            (status, actioned_by, now, result, id),
        )
        await db.commit()


async def get_recent_actions(db_path: str, limit: int = 50) -> list[dict]:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM actions ORDER BY requested_at DESC LIMIT ?",
            (limit,),
        )
        rows = await cursor.fetchall()
        return [dict(row) for row in rows]


async def get_action_by_id(db_path: str, action_id: str) -> Optional[dict]:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM actions WHERE id = ?",
            (action_id,),
        )
        row = await cursor.fetchone()
        return dict(row) if row else None
