"""plaid items + account link

Revision ID: 0004_plaid_items
Revises: 0003_group_archive_hide
Create Date: 2026-06-18

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0004_plaid_items"
down_revision: str | None = "0003_group_archive_hide"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "plaid_items",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("plaid_item_id", sa.String(128), nullable=False),
        sa.Column("access_token", sa.String(256), nullable=False),
        sa.Column("institution_name", sa.String(255), nullable=True),
        sa.Column("transactions_cursor", sa.Text(), nullable=True),
        sa.Column("user_identifier", sa.String(128), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("plaid_item_id", name="uq_plaid_items_plaid_item_id"),
    )

    op.add_column(
        "accounts",
        sa.Column(
            "plaid_item_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("plaid_items.id", ondelete="CASCADE"),
            nullable=True,
        ),
    )


def downgrade() -> None:
    op.drop_column("accounts", "plaid_item_id")
    op.drop_table("plaid_items")
