"""per-(owner, account) override table

Moves the per-account user overrides off the single `accounts` columns into an `account_overrides` table keyed
by `(owner_identifier, account_id)`, so they're per-user — independent under a future shared account. The
Plaid-sourced columns stay on `accounts`. Backfills existing overrides (keyed by the account's owner), then
drops the four columns.

Revision ID: 0028_account_overrides
Revises: 0027_txn_category_overrides
Create Date: 2026-06-24

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

# Note: revision id kept <= 32 chars to fit Alembic's alembic_version.version_num (varchar(32)).
revision: str = "0028_account_overrides"
down_revision: str | None = "0027_txn_category_overrides"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "account_overrides",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column(
            "account_id", UUID(as_uuid=True),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("display_name", sa.String(255), nullable=True),
        sa.Column("kind", sa.String(16), nullable=True),
        sa.Column("include_in_spending", sa.Boolean(), nullable=True),
        sa.Column("include_in_cash_flow", sa.Boolean(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("owner_identifier", "account_id", name="uq_account_override_owner_account"),
    )
    op.create_index("ix_account_override_owner", "account_overrides", ["owner_identifier"])
    op.create_index("ix_account_override_account", "account_overrides", ["account_id"])

    # Backfill existing overrides, keyed by the account's current owner.
    op.execute(
        "INSERT INTO account_overrides "
        "(id, owner_identifier, account_id, display_name, kind, include_in_spending, include_in_cash_flow, "
        " created_at, updated_at) "
        "SELECT gen_random_uuid(), owner_identifier, id, display_name, kind, include_in_spending, "
        "       include_in_cash_flow, now(), now() "
        "FROM accounts WHERE owner_identifier IS NOT NULL AND ("
        "  display_name IS NOT NULL OR kind IS NOT NULL "
        "  OR include_in_spending IS NOT NULL OR include_in_cash_flow IS NOT NULL)"
    )

    op.drop_column("accounts", "display_name")
    op.drop_column("accounts", "kind")
    op.drop_column("accounts", "include_in_spending")
    op.drop_column("accounts", "include_in_cash_flow")


def downgrade() -> None:
    op.add_column("accounts", sa.Column("display_name", sa.String(length=255), nullable=True))
    op.add_column("accounts", sa.Column("kind", sa.String(length=16), nullable=True))
    op.add_column("accounts", sa.Column("include_in_spending", sa.Boolean(), nullable=True))
    op.add_column("accounts", sa.Column("include_in_cash_flow", sa.Boolean(), nullable=True))
    # Copy back the override matching the account's owner (best-effort; a shared account may have multiple).
    op.execute(
        "UPDATE accounts a SET display_name = o.display_name, kind = o.kind, "
        "  include_in_spending = o.include_in_spending, include_in_cash_flow = o.include_in_cash_flow "
        "FROM account_overrides o "
        "WHERE o.account_id = a.id AND o.owner_identifier = a.owner_identifier"
    )
    op.drop_index("ix_account_override_account", table_name="account_overrides")
    op.drop_index("ix_account_override_owner", table_name="account_overrides")
    op.drop_table("account_overrides")
