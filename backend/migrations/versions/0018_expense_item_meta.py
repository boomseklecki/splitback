"""expense_items: owner + provenance (added/edited by)

Revision ID: 0018_expense_item_meta
Revises: 0017_categories
Create Date: 2026-06-20

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0018_expense_item_meta"
down_revision: str | None = "0017_categories"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("expense_items", sa.Column("owner_identifier", sa.String(length=255), nullable=True))
    op.add_column("expense_items", sa.Column("created_by", sa.String(length=255), nullable=True))
    op.add_column("expense_items", sa.Column("updated_by", sa.String(length=255), nullable=True))


def downgrade() -> None:
    op.drop_column("expense_items", "updated_by")
    op.drop_column("expense_items", "created_by")
    op.drop_column("expense_items", "owner_identifier")
