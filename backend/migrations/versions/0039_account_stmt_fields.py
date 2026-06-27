"""account fields for statement (OFX) import

Adds `external_account_id` (stable statement account id for find-or-create/dedup), `available_balance`
(available credit), and `balance_as_of` (the statement date the cached balance/available reflect) to
`accounts`. Partial unique index on (owner_identifier, external_account_id) so one account per statement
identity (Plaid rows leave it null).

Revision ID: 0039_account_stmt_fields
Revises: 0038_external_transaction_id
Create Date: 2026-06-27

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0039_account_stmt_fields"
down_revision: str | None = "0038_external_transaction_id"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("accounts", sa.Column("external_account_id", sa.String(128), nullable=True))
    op.add_column("accounts", sa.Column("available_balance", sa.Numeric(12, 2), nullable=True))
    op.add_column("accounts", sa.Column("balance_as_of", sa.Date(), nullable=True))
    op.create_index(
        "uq_account_owner_external", "accounts",
        ["owner_identifier", "external_account_id"], unique=True,
        postgresql_where=sa.text("external_account_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("uq_account_owner_external", table_name="accounts")
    op.drop_column("accounts", "balance_as_of")
    op.drop_column("accounts", "available_balance")
    op.drop_column("accounts", "external_account_id")
