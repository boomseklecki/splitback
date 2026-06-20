"""account inclusion flags for Goals analytics

Revision ID: 0015_account_flags
Revises: 0014_goals
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0015_account_flags"
down_revision: str | None = "0014_goals"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("accounts", sa.Column("include_in_spending", sa.Boolean(), nullable=True))
    op.add_column("accounts", sa.Column("include_in_cash_flow", sa.Boolean(), nullable=True))


def downgrade() -> None:
    op.drop_column("accounts", "include_in_cash_flow")
    op.drop_column("accounts", "include_in_spending")
