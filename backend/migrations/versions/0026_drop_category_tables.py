"""drop the unused shared category tables

Categories are now local-authoritative (per user): the canonical taxonomy is hardcoded on-device
(`CanonicalCategory.all`) and seeded locally for every new user, and a user's customizations sync via the
per-owner `user_preferences` blob (`categories.v1`, see 0025). The old global `categories` + `category_map`
tables are unused by the app and the backend never read them, so just drop them. (No data backfill: existing
customizations were already preserved into the per-user blob, and `user_preferences` keeps being written by
the app — this migration is a one-time table removal, not a gate on creating blobs.)

Revision ID: 0026_drop_category_tables
Revises: 0025_user_preferences
Create Date: 2026-06-24

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0026_drop_category_tables"
down_revision: str | None = "0025_user_preferences"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
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
