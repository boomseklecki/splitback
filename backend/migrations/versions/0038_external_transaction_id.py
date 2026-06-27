"""transaction external id for statement (OFX) import dedup

Adds `external_transaction_id` (e.g. an OFX FITID) to `transactions`, with a partial composite unique index
on (account_id, external_transaction_id) — FITIDs are unique per account, not globally (unlike Plaid ids), so
re-importing an overlapping statement upserts instead of duplicating.

Revision ID: 0038_external_transaction_id
Revises: 0037_device_public_key
Create Date: 2026-06-26

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0038_external_transaction_id"
down_revision: str | None = "0037_device_public_key"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("transactions", sa.Column("external_transaction_id", sa.String(128), nullable=True))
    op.create_index(
        "uq_txn_account_external", "transactions",
        ["account_id", "external_transaction_id"], unique=True,
        postgresql_where=sa.text("external_transaction_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("uq_txn_account_external", table_name="transactions")
    op.drop_column("transactions", "external_transaction_id")
