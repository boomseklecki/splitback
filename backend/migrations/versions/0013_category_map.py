"""category_map table (raw Plaid category -> canonical category)

Revision ID: 0013_category_map
Revises: 0012_expense_sw_metadata
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0013_category_map"
down_revision: str | None = "0012_expense_sw_metadata"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
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


def downgrade() -> None:
    op.drop_table("category_map")
