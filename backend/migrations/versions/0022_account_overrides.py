"""account display_name + kind overrides

Revision ID: 0022_account_overrides
Revises: 0021_encrypt_tokens
Create Date: 2026-06-22

User-set display name and classification (cash_flow/liability/savings) overrides. Both nullable (null =
fall back to Plaid's name / derived classification); they survive a Plaid re-sync the same way the
inclusion flags do (sync only updates name/type/balance/currency).
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0022_account_overrides"
down_revision: str | None = "0021_encrypt_tokens"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("accounts", sa.Column("display_name", sa.String(length=255), nullable=True))
    op.add_column("accounts", sa.Column("kind", sa.String(length=16), nullable=True))


def downgrade() -> None:
    op.drop_column("accounts", "kind")
    op.drop_column("accounts", "display_name")
