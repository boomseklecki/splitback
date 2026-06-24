"""migrate shared category tables into per-user preference blobs, then drop them

Categories are now local-authoritative (per user) and synced via the per-owner `user_preferences` blob
(see 0025). The old global `categories` + `category_map` tables are unused by the app and the backend never
read them. This migration first preserves any customizations: it builds the `categories.v1` snapshot (the
iOS `CategorySnapshot` shape) from the shared tables and seeds it for every user (ON CONFLICT DO NOTHING, so
a device that already pushed its own blob is never overwritten) — then drops the tables. Runs safely in a
single `alembic upgrade head`, so no manual data-migration step is needed.

Revision ID: 0026_drop_category_tables
Revises: 0025_user_preferences
Create Date: 2026-06-24

"""
import json
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0026_drop_category_tables"
down_revision: str | None = "0025_user_preferences"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    conn = op.get_bind()
    cats = conn.execute(sa.text(
        "SELECT name, builtin, position, icon FROM categories ORDER BY position, name")).mappings().all()
    maps = conn.execute(sa.text(
        "SELECT raw_category, canonical_category, source FROM category_map ORDER BY raw_category")
    ).mappings().all()

    # Only seed a blob when there's something worth preserving (a manual map, a custom category, or a
    # custom icon) — a pristine default taxonomy is reproduced locally by the app's built-in seed anyway.
    has_custom = bool(maps) or any(not c["builtin"] or c["icon"] for c in cats)
    if has_custom:
        snapshot = {
            "version": 1,
            "categories": [
                {"name": c["name"], "icon": c["icon"], "position": c["position"], "builtin": c["builtin"]}
                for c in cats
            ],
            "maps": [
                {"rawCategory": m["raw_category"], "canonicalCategory": m["canonical_category"],
                 "source": m["source"]}
                for m in maps
            ],
        }
        value = json.dumps(snapshot, separators=(",", ":"), ensure_ascii=False)
        conn.execute(
            sa.text(
                "INSERT INTO user_preferences (id, owner_identifier, key, value, created_at, updated_at) "
                "SELECT gen_random_uuid(), u.identifier, 'categories.v1', :value, now(), now() FROM users u "
                "ON CONFLICT (owner_identifier, key) DO NOTHING"
            ),
            {"value": value},
        )

    op.drop_table("category_map")
    op.drop_table("categories")


def downgrade() -> None:
    # Recreate the (empty) tables and reseed the built-in taxonomy; custom data is not restored.
    from app.categories import CATEGORIES

    op.create_table(
        "category_map",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("raw_category", sa.String(128), nullable=False),
        sa.Column("canonical_category", sa.String(64), nullable=False),
        sa.Column("source", sa.String(16), nullable=False, server_default="manual"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("raw_category", name="uq_category_map_raw_category"),
    )
    categories = op.create_table(
        "categories",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("name", sa.String(64), nullable=False),
        sa.Column("builtin", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("position", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("icon", sa.String(64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("name", name="uq_categories_name"),
    )
    op.bulk_insert(
        categories,
        [{"name": name, "builtin": True, "position": i} for i, name in enumerate(CATEGORIES)],
    )
