"""per-(owner, transaction) category override table

Moves the per-transaction category override off the single `transactions.category_override` column into a
`transaction_category_overrides` table keyed by `(owner_identifier, transaction_id)`, so overrides are
per-user — independent under a future shared transaction. Backfills existing overrides (keyed by the
transaction's current owner), then drops the column.

Revision ID: 0027_txn_category_overrides
Revises: 0026_drop_category_tables
Create Date: 2026-06-24

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

# Note: revision id kept <= 32 chars to fit Alembic's alembic_version.version_num (varchar(32)).
revision: str = "0027_txn_category_overrides"
down_revision: str | None = "0026_drop_category_tables"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "transaction_category_overrides",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column(
            "transaction_id", UUID(as_uuid=True),
            sa.ForeignKey("transactions.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("category", sa.String(128), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("owner_identifier", "transaction_id", name="uq_txn_override_owner_txn"),
    )
    op.create_index(
        "ix_txn_override_owner", "transaction_category_overrides", ["owner_identifier"]
    )
    op.create_index(
        "ix_txn_override_transaction", "transaction_category_overrides", ["transaction_id"]
    )

    # Backfill existing overrides, keyed by the transaction's current owner.
    op.execute(
        "INSERT INTO transaction_category_overrides "
        "(id, owner_identifier, transaction_id, category, created_at, updated_at) "
        "SELECT gen_random_uuid(), owner_identifier, id, category_override, now(), now() "
        "FROM transactions WHERE category_override IS NOT NULL AND owner_identifier IS NOT NULL"
    )

    op.drop_column("transactions", "category_override")


def downgrade() -> None:
    op.add_column("transactions", sa.Column("category_override", sa.String(length=128), nullable=True))
    # Copy back the override that matches the transaction's owner (best-effort; a shared transaction may have
    # multiple per-user overrides — only the owner's is representable in the single column).
    op.execute(
        "UPDATE transactions t SET category_override = o.category "
        "FROM transaction_category_overrides o "
        "WHERE o.transaction_id = t.id AND o.owner_identifier = t.owner_identifier"
    )
    op.drop_index("ix_txn_override_transaction", table_name="transaction_category_overrides")
    op.drop_index("ix_txn_override_owner", table_name="transaction_category_overrides")
    op.drop_table("transaction_category_overrides")
