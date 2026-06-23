"""account mask (last few digits)

Revision ID: 0023_account_mask
Revises: 0022_account_overrides
Create Date: 2026-06-23

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0023_account_mask"
down_revision: str | None = "0022_account_overrides"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("accounts", sa.Column("mask", sa.String(length=32), nullable=True))


def downgrade() -> None:
    op.drop_column("accounts", "mask")
