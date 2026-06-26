"""remove archive/soft-delete; per-user include-in-spending/cash-flow overrides

Replaces the archive concept with real delete + per-user budget overrides:
- drop `expenses.archived_at` (delete is now always a hard-delete);
- rename `groups.archived_at` -> `superseded_at` (internal import_group_local marker only);
- new `expense_overrides`; add include flags to `group_overrides`;
- rename `transaction_category_overrides` -> `transaction_overrides` + include flags + nullable category;
- drop the two hard-delete server settings.

Revision ID: 0033_delete_include_overrides
Revises: 0032_refresh_provider_thresholds
Create Date: 2026-06-25

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

# Note: revision id kept <= 32 chars to fit Alembic's alembic_version.version_num (varchar(32)).
revision: str = "0033_delete_include_overrides"
down_revision: str | None = "0032_refresh_provider_thresholds"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Archive -> gone. Expenses hard-delete now; groups keep an internal superseded marker for import-local.
    op.drop_column("expenses", "archived_at")
    op.alter_column("groups", "archived_at", new_column_name="superseded_at")

    op.create_table(
        "expense_overrides",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column("expense_id", UUID(as_uuid=True), sa.ForeignKey("expenses.id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("include_in_spending", sa.Boolean(), nullable=True),
        sa.Column("include_in_cash_flow", sa.Boolean(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("owner_identifier", "expense_id", name="uq_expense_override_owner_expense"),
    )
    op.create_index("ix_expense_override_owner", "expense_overrides", ["owner_identifier"])
    op.create_index("ix_expense_override_expense", "expense_overrides", ["expense_id"])

    op.add_column("group_overrides", sa.Column("include_in_spending", sa.Boolean(), nullable=True))
    op.add_column("group_overrides", sa.Column("include_in_cash_flow", sa.Boolean(), nullable=True))

    op.rename_table("transaction_category_overrides", "transaction_overrides")
    op.add_column("transaction_overrides", sa.Column("include_in_spending", sa.Boolean(), nullable=True))
    op.add_column("transaction_overrides", sa.Column("include_in_cash_flow", sa.Boolean(), nullable=True))
    op.alter_column("transaction_overrides", "category", existing_type=sa.String(128), nullable=True)

    op.execute(
        "DELETE FROM server_settings "
        "WHERE key IN ('expenses_hard_delete_enabled', 'groups_hard_delete_enabled')"
    )


def downgrade() -> None:
    op.execute(
        "INSERT INTO server_settings (key, value) VALUES "
        "('expenses_hard_delete_enabled', 'false'), ('groups_hard_delete_enabled', 'false') "
        "ON CONFLICT (key) DO NOTHING"
    )

    op.alter_column("transaction_overrides", "category", existing_type=sa.String(128), nullable=False)
    op.drop_column("transaction_overrides", "include_in_cash_flow")
    op.drop_column("transaction_overrides", "include_in_spending")
    op.rename_table("transaction_overrides", "transaction_category_overrides")

    op.drop_column("group_overrides", "include_in_cash_flow")
    op.drop_column("group_overrides", "include_in_spending")

    op.drop_index("ix_expense_override_expense", table_name="expense_overrides")
    op.drop_index("ix_expense_override_owner", table_name="expense_overrides")
    op.drop_table("expense_overrides")

    op.alter_column("groups", "superseded_at", new_column_name="archived_at")
    op.add_column("expenses", sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True))
