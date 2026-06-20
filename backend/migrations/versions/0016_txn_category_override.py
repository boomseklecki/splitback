"""per-transaction category override

Revision ID: 0016_txn_category_override
Revises: 0015_account_flags
Create Date: 2026-06-20

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0016_txn_category_override"
down_revision: str | None = "0015_account_flags"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("transactions", sa.Column("category_override", sa.String(length=128), nullable=True))


def downgrade() -> None:
    op.drop_column("transactions", "category_override")
