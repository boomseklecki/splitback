"""institution branding metadata

Revision ID: 0024_institution_metadata
Revises: 0023_account_mask
Create Date: 2026-06-23

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0024_institution_metadata"
down_revision: str | None = "0023_account_mask"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("plaid_items", sa.Column("institution_id", sa.String(length=64), nullable=True))
    op.add_column("plaid_items", sa.Column("institution_domain", sa.String(length=255), nullable=True))
    op.add_column("plaid_items", sa.Column("institution_color", sa.String(length=16), nullable=True))
    op.add_column("plaid_items", sa.Column("institution_status", sa.String(length=32), nullable=True))
    op.add_column("accounts", sa.Column("institution_name", sa.String(length=255), nullable=True))
    op.add_column("accounts", sa.Column("institution_domain", sa.String(length=255), nullable=True))
    op.add_column("accounts", sa.Column("institution_color", sa.String(length=16), nullable=True))
    op.add_column("accounts", sa.Column("institution_status", sa.String(length=32), nullable=True))


def downgrade() -> None:
    for col in ("institution_status", "institution_color", "institution_domain", "institution_name"):
        op.drop_column("accounts", col)
    for col in ("institution_status", "institution_color", "institution_domain", "institution_id"):
        op.drop_column("plaid_items", col)
