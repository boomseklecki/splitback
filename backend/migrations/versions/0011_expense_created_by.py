"""expense created_by (who added it, from Splitwise)

Revision ID: 0011_expense_created_by
Revises: 0010_sw_sync_cursor
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0011_expense_created_by"
down_revision: str | None = "0010_sw_sync_cursor"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("expenses", sa.Column("created_by", sa.String(128), nullable=True))


def downgrade() -> None:
    op.drop_column("expenses", "created_by")
