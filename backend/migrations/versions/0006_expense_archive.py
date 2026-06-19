"""expense archive marker

Revision ID: 0006_expense_archive
Revises: 0005_users_members
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0006_expense_archive"
down_revision: str | None = "0005_users_members"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "expenses",
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("expenses", "archived_at")
