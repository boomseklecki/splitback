"""pending_transaction_id on transactions

Persists Plaid's `pending_transaction_id` (the pending charge's id that a posted row replaced) as a plain
string on the posted row, so the app can point a user from a since-posted pending transaction to its posted
twin. Indexed for that lookup; nullable (Plaid posted rows only).

Revision ID: 0040_pending_txn_id
Revises: 0039_account_stmt_fields
Create Date: 2026-06-28

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0040_pending_txn_id"
down_revision: str | None = "0039_account_stmt_fields"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("transactions", sa.Column("pending_transaction_id", sa.String(128), nullable=True))
    op.create_index(
        "ix_transactions_pending_transaction_id", "transactions", ["pending_transaction_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_transactions_pending_transaction_id", table_name="transactions")
    op.drop_column("transactions", "pending_transaction_id")
