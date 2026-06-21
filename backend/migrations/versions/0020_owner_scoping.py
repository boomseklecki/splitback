"""owner_identifier on accounts/transactions/goals (per-caller scoping) + backfill

Revision ID: 0020_owner_scoping
Revises: 0019_transaction_items
Create Date: 2026-06-20

Backfill order: accounts <- plaid_items.user_identifier (the linker); transactions <- their account's
owner; then any still-NULL account/transaction/goal -> SCOPING_PRIMARY_OWNER (env), so existing manual data
stays visible to its primary owner. Set SCOPING_PRIMARY_OWNER in the env before upgrading.
"""
import os
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0020_owner_scoping"
down_revision: str | None = "0019_transaction_items"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("accounts", sa.Column("owner_identifier", sa.String(length=128), nullable=True))
    op.add_column("transactions", sa.Column("owner_identifier", sa.String(length=128), nullable=True))
    op.add_column("goals", sa.Column("owner_identifier", sa.String(length=128), nullable=True))

    # Plaid accounts -> the linker; transactions -> their account's owner.
    op.execute(
        "UPDATE accounts a SET owner_identifier = p.user_identifier "
        "FROM plaid_items p WHERE a.plaid_item_id = p.id AND a.owner_identifier IS NULL"
    )
    op.execute(
        "UPDATE transactions t SET owner_identifier = a.owner_identifier "
        "FROM accounts a WHERE t.account_id = a.id AND t.owner_identifier IS NULL"
    )

    # Remaining unowned rows (manual accounts/cash transactions/goals) -> the primary owner. Guard: if any
    # would be left NULL (invisible under per-caller scoping) and SCOPING_PRIMARY_OWNER isn't set, abort so
    # the operator can't silently hide their data — set it and re-run. The backfill is parameterized.
    bind = op.get_bind()
    primary = (os.environ.get("SCOPING_PRIMARY_OWNER") or "").strip()
    remaining = sum(
        bind.execute(
            sa.text(f"SELECT count(*) FROM {table} WHERE owner_identifier IS NULL")
        ).scalar() or 0
        for table in ("accounts", "transactions", "goals")
    )
    if remaining and not primary:
        raise RuntimeError(
            f"{remaining} accounts/transactions/goals would be left un-owned and invisible under per-caller "
            "scoping. Set SCOPING_PRIMARY_OWNER to your /me identifier and re-run `alembic upgrade head`."
        )
    if primary:
        for table in ("accounts", "transactions", "goals"):
            op.execute(
                sa.text(f"UPDATE {table} SET owner_identifier = :owner WHERE owner_identifier IS NULL")
                .bindparams(owner=primary)
            )


def downgrade() -> None:
    op.drop_column("goals", "owner_identifier")
    op.drop_column("transactions", "owner_identifier")
    op.drop_column("accounts", "owner_identifier")
