"""expense splitwise metadata (added/edited provenance, notes, recurrence)

Revision ID: 0012_expense_sw_metadata
Revises: 0011_expense_created_by
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0012_expense_sw_metadata"
down_revision: str | None = "0011_expense_created_by"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("expenses", sa.Column("splitwise_created_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("expenses", sa.Column("splitwise_updated_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("expenses", sa.Column("updated_by", sa.String(128), nullable=True))
    op.add_column("expenses", sa.Column("notes", sa.Text(), nullable=True))
    op.add_column("expenses", sa.Column("comments_count", sa.Integer(), nullable=True))
    op.add_column("expenses", sa.Column("repeats", sa.Boolean(), nullable=True))
    op.add_column("expenses", sa.Column("repeat_interval", sa.String(32), nullable=True))
    op.add_column("expenses", sa.Column("expense_bundle_id", sa.String(64), nullable=True))


def downgrade() -> None:
    op.drop_column("expenses", "expense_bundle_id")
    op.drop_column("expenses", "repeat_interval")
    op.drop_column("expenses", "repeats")
    op.drop_column("expenses", "comments_count")
    op.drop_column("expenses", "notes")
    op.drop_column("expenses", "updated_by")
    op.drop_column("expenses", "splitwise_updated_at")
    op.drop_column("expenses", "splitwise_created_at")
