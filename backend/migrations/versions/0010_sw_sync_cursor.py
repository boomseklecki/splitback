"""splitwise incremental-sync cursor on tokens

Revision ID: 0010_sw_sync_cursor
Revises: 0009_group_expense_sw_extras
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0010_sw_sync_cursor"
down_revision: str | None = "0009_group_expense_sw_extras"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "splitwise_tokens",
        sa.Column("expenses_synced_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("splitwise_tokens", "expenses_synced_at")
