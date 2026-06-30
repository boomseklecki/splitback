"""backfill categories.v1 blobs into the relational category tables

Existing users only have their taxonomy + raw→canonical map inside the opaque `categories.v1` preferences
blob. Parse each owner's blob (a JSON `CategorySnapshot`: `{version, categories:[{name,icon,position,
builtin}], maps:[{rawCategory,canonicalCategory,source}]}`) into `spend_categories` + `category_maps`, so the
server is category-aware for users who upgrade the app but never re-launch onto the new relational sync.

Defensive: each owner is isolated in try/except — a malformed blob is skipped and logged, never failing the
migration. An owner that already has rows (e.g. the new client pushed first) is skipped. The original blob is
left untouched (Phase 5 deletes it after adoption), so this is non-destructive and `downgrade` is a no-op —
we never delete user data on downgrade.

Revision ID: 0047_categories_backfill
Revises: 0046_txn_refined_category
Create Date: 2026-06-30

"""
import json
import logging
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0047_categories_backfill"
down_revision: str | None = "0046_txn_refined_category"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

log = logging.getLogger("alembic.runtime.migration")

_BLOB_KEY = "categories.v1"


def upgrade() -> None:
    bind = op.get_bind()
    blobs = bind.execute(
        sa.text(
            "SELECT owner_identifier, value FROM user_preferences WHERE key = :k"
        ),
        {"k": _BLOB_KEY},
    ).fetchall()

    insert_cat = sa.text(
        "INSERT INTO spend_categories (owner_identifier, name, builtin, position, icon) "
        "VALUES (:owner, :name, :builtin, :position, :icon) "
        "ON CONFLICT (owner_identifier, name) DO NOTHING"
    )
    insert_map = sa.text(
        "INSERT INTO category_maps (owner_identifier, raw_category, canonical_category, source) "
        "VALUES (:owner, :raw, :canonical, :source) "
        "ON CONFLICT (owner_identifier, raw_category) DO NOTHING"
    )
    has_rows = sa.text(
        "SELECT 1 FROM spend_categories WHERE owner_identifier = :owner LIMIT 1"
    )

    migrated = 0
    for owner, value in blobs:
        try:
            # Skip owners whose relational rows already exist (client pushed before this ran).
            if bind.execute(has_rows, {"owner": owner}).first() is not None:
                continue
            snap = json.loads(value)
            seen_names: set[str] = set()
            for c in snap.get("categories", []):
                name = c.get("name")
                if not name or name in seen_names:
                    continue
                seen_names.add(name)
                bind.execute(insert_cat, {
                    "owner": owner, "name": name,
                    "builtin": bool(c.get("builtin", False)),
                    "position": int(c.get("position", 0)),
                    "icon": c.get("icon"),
                })
            seen_raw: set[str] = set()
            for m in snap.get("maps", []):
                raw = m.get("rawCategory")
                canonical = m.get("canonicalCategory")
                if not raw or not canonical or raw in seen_raw:
                    continue
                seen_raw.add(raw)
                bind.execute(insert_map, {
                    "owner": owner, "raw": raw, "canonical": canonical,
                    "source": m.get("source") or "manual",
                })
            migrated += 1
        except Exception as exc:  # noqa: BLE001 — never fail the migration on one bad blob
            log.warning("categories.v1 backfill skipped owner %r: %s", owner, exc)
    log.info("categories.v1 backfill: migrated %d/%d owners", migrated, len(blobs))


def downgrade() -> None:
    # Intentional no-op: the source blobs were never removed, so there's nothing to restore and we must not
    # delete the user's (now relational) category data.
    pass
