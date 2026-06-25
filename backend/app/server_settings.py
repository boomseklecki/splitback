"""Server-global runtime settings (admin-editable), backed by the `server_settings` table.

A typed registry of known keys + defaults; each value is JSON-encoded in the row's `value` column. This
replaces the former `.env` policy vars (invite policy, hard-delete toggles, scheduler intervals, public
hostname) so an admin can change them in-app without a redeploy. Reads return the registry default when a row
is absent, so the store is safe before migration 0030 seeds it. Reads happen on cold paths (server-info,
deletes, scheduler poll), so no caching is needed.
"""
import json

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ServerSetting

# key -> (python type, default). Bools/ints are coerced on read and write.
REGISTRY: dict[str, tuple[type, object]] = {
    "invites_open_to_members": (bool, False),
    "public_hostname": (str, ""),
    "groups_hard_delete_enabled": (bool, False),
    "expenses_hard_delete_enabled": (bool, False),
    "splitwise_receipt_download_enabled": (bool, False),
    "sync_interval_hours": (int, 0),
    "backup_interval_hours": (int, 0),
    "backups_retention_days": (int, 30),
    "backups_retention_min_keep": (int, 7),
}


def _coerce(key: str, value: object) -> object:
    typ, _ = REGISTRY[key]
    if typ is bool:
        return bool(value)
    if typ is int:
        return int(value)  # type: ignore[arg-type]
    return str(value)


def _decode(key: str, raw: str) -> object:
    try:
        return _coerce(key, json.loads(raw))
    except (ValueError, TypeError):
        return REGISTRY[key][1]


async def get(session: AsyncSession, key: str) -> object:
    """The current value for `key` (the registry default when no row exists / on a decode error)."""
    if key not in REGISTRY:
        raise KeyError(key)
    row = await session.get(ServerSetting, key)
    return _decode(key, row.value) if row is not None else REGISTRY[key][1]


async def get_all(session: AsyncSession) -> dict[str, object]:
    """Every registry key resolved to its current (or default) value — the shape the API returns."""
    rows = {r.key: r for r in await session.scalars(select(ServerSetting))}
    return {
        key: (_decode(key, rows[key].value) if key in rows else default)
        for key, (_typ, default) in REGISTRY.items()
    }


async def set_value(session: AsyncSession, key: str, value: object) -> None:
    """Upsert `key` (type-validated against the registry). Caller commits."""
    if key not in REGISTRY:
        raise KeyError(key)
    payload = json.dumps(_coerce(key, value))
    await session.execute(
        pg_insert(ServerSetting)
        .values(key=key, value=payload)
        .on_conflict_do_update(index_elements=[ServerSetting.key], set_={"value": payload})
    )
