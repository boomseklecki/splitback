"""per-owner category taxonomy + raw->canonical map tables

Brings categories onto the backend (relationally) so the server can resolve a transaction's canonical
category — the foundation for server-side spend/budget computation. These replace the `categories.v1`
preferences blob's `categories`/`maps` arrays; migration 0047 backfills existing blobs into them. Mirrors the
historically-dropped global tables (0026) plus `owner_identifier` scoping (owner-scoped uniqueness, unlike the
old global constraints).

Revision ID: 0045_category_tables
Revises: 0044_notification_hidden
Create Date: 2026-06-30

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0045_category_tables"
down_revision: str | None = "0044_notification_hidden"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "spend_categories",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column("name", sa.String(64), nullable=False),
        sa.Column("builtin", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("position", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("icon", sa.String(64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("owner_identifier", "name", name="uq_spend_categories_owner_name"),
    )
    op.create_index("ix_spend_categories_owner", "spend_categories", ["owner_identifier"])

    op.create_table(
        "category_maps",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column("raw_category", sa.String(128), nullable=False),
        sa.Column("canonical_category", sa.String(64), nullable=False),
        sa.Column("source", sa.String(16), nullable=False, server_default="manual"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("owner_identifier", "raw_category", name="uq_category_maps_owner_raw"),
    )
    op.create_index("ix_category_maps_owner", "category_maps", ["owner_identifier"])


def downgrade() -> None:
    op.drop_index("ix_category_maps_owner", table_name="category_maps")
    op.drop_table("category_maps")
    op.drop_index("ix_spend_categories_owner", table_name="spend_categories")
    op.drop_table("spend_categories")
