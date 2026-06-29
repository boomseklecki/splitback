"""Server-global runtime settings (admin-editable), backed by the `server_settings` table.

A typed registry of known keys + defaults; each value is JSON-encoded in the row's `value` column. This
replaces the former `.env` policy vars (invite policy, hard-delete toggles, scheduler intervals, public
hostname) so an admin can change them in-app without a redeploy. Reads return the registry default when a row
is absent, so the store is safe before migration 0030 seeds it. Reads happen on cold paths (server-info,
deletes, scheduler poll), so no caching is needed.
"""
import json
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ServerSetting

# key -> (python type, default). Bools/ints are coerced on read and write.
REGISTRY: dict[str, tuple[type, object]] = {
    "invites_open_to_members": (bool, False),
    "public_hostname": (str, ""),
    "splitwise_receipt_download_enabled": (bool, False),   # convert-to-local + per-group receipt download
    "splitwise_receipt_backfill_enabled": (bool, False),   # the bulk download-all button + scheduled auto-backfill
    "sync_interval_hours": (int, 0),
    "backup_interval_hours": (int, 0),
    "backups_retention_days": (int, 30),
    "backups_retention_min_keep": (int, 7),
    # Smart pull-to-refresh: a live provider sync fires only when the in-scope data is staler than the
    # provider's threshold (minutes); otherwise it just reconciles. Split by provider because Plaid calls
    # cost money (sync less often) while Splitwise is free. Scope comes from the freshness signal each
    # screen passes, not from a per-level threshold.
    "refresh_plaid_stale_minutes": (int, 60),       # any bank (Plaid) pull-to-refresh
    "refresh_splitwise_stale_minutes": (int, 15),   # any Splitwise pull-to-refresh
    # Notifications: cap stored per-owner notifications to the most recent N (prune on each sync).
    "notifications_retention_count": (int, 100),
    # Fast notifications-only poll cadence (minutes); 0 = off. Makes Splitwise partner-activity pushes
    # near-real-time instead of waiting for the slow full-sync interval.
    "notifications_poll_minutes": (int, 0),
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


# --- Internal markers ---------------------------------------------------------------------------------
# Timestamps the schedulers persist (e.g. last sync/backup run) so a redeploy doesn't reset their interval.
# These keys are NOT in REGISTRY, so they never surface in get_all() / the /server-settings API.

async def get_timestamp(session: AsyncSession, key: str) -> datetime | None:
    """The stored timestamp for an internal marker `key`, or None when absent/unparseable."""
    row = await session.get(ServerSetting, key)
    if row is None:
        return None
    try:
        return datetime.fromisoformat(json.loads(row.value))
    except (ValueError, TypeError):
        return None


async def set_timestamp(session: AsyncSession, key: str, value: datetime) -> None:
    """Upsert an internal timestamp marker (ISO-8601). Caller commits."""
    payload = json.dumps(value.isoformat())
    await session.execute(
        pg_insert(ServerSetting)
        .values(key=key, value=payload)
        .on_conflict_do_update(index_elements=[ServerSetting.key], set_={"value": payload})
    )
