"""initial schema

Revision ID: 0001_initial
Revises:
Create Date: 2026-06-18

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001_initial"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


backend_type = postgresql.ENUM(
    "self_hosted", "splitwise", name="backend_type", create_type=False
)
transaction_source = postgresql.ENUM(
    "plaid", "manual", name="transaction_source", create_type=False
)


def upgrade() -> None:
    bind = op.get_bind()
    backend_type.create(bind, checkfirst=True)
    transaction_source.create(bind, checkfirst=True)

    op.create_table(
        "groups",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("backend_type", backend_type, nullable=False),
        sa.Column("splitwise_group_id", sa.String(64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )

    op.create_table(
        "accounts",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("type", sa.String(64), nullable=True),
        sa.Column("plaid_account_id", sa.String(128), nullable=True),
        sa.Column("balance", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("currency", sa.String(3), nullable=False, server_default="USD"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("plaid_account_id", name="uq_accounts_plaid_account_id"),
    )

    op.create_table(
        "transactions",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("account_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("accounts.id", ondelete="SET NULL"), nullable=True),
        sa.Column("plaid_transaction_id", sa.String(128), nullable=True),
        sa.Column("source", transaction_source, nullable=False),
        sa.Column("description", sa.String(512), nullable=False),
        sa.Column("amount", sa.Numeric(12, 2), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False, server_default="USD"),
        sa.Column("date", sa.Date, nullable=False),
        sa.Column("category", sa.String(128), nullable=True),
        sa.Column("pending", sa.Boolean, nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("plaid_transaction_id", name="uq_transactions_plaid_transaction_id"),
    )

    op.create_table(
        "expenses",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("group_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("groups.id", ondelete="CASCADE"), nullable=False),
        sa.Column("transaction_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("transactions.id", ondelete="SET NULL"), nullable=True),
        sa.Column("splitwise_expense_id", sa.String(64), nullable=True),
        sa.Column("description", sa.String(512), nullable=False),
        sa.Column("amount", sa.Numeric(12, 2), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False, server_default="USD"),
        sa.Column("date", sa.Date, nullable=False),
        sa.Column("category", sa.String(128), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("splitwise_expense_id", name="uq_expenses_splitwise_expense_id"),
    )

    op.create_table(
        "expense_items",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("expense_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("expenses.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("quantity", sa.Numeric(10, 3), nullable=False, server_default="1"),
        sa.Column("price", sa.Numeric(12, 2), nullable=False),
        sa.Column("category", sa.String(128), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )

    op.create_table(
        "splits",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("expense_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("expenses.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_identifier", sa.String(128), nullable=False),
        sa.Column("paid_share", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("owed_share", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )

    op.create_table(
        "receipts",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("expense_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("expenses.id", ondelete="CASCADE"), nullable=False),
        sa.Column("bucket", sa.String(128), nullable=False),
        sa.Column("object_key", sa.String(512), nullable=False),
        sa.Column("content_type", sa.String(128), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("receipts")
    op.drop_table("splits")
    op.drop_table("expense_items")
    op.drop_table("expenses")
    op.drop_table("transactions")
    op.drop_table("accounts")
    op.drop_table("groups")
    transaction_source.drop(op.get_bind(), checkfirst=True)
    backend_type.drop(op.get_bind(), checkfirst=True)
