"""group type/avatar/cover + expense receipt url/repayments from splitwise

Revision ID: 0009_group_expense_splitwise_extras
Revises: 0008_user_registration_status
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "0009_group_expense_splitwise_extras"
down_revision: str | None = "0008_user_registration_status"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("groups", sa.Column("group_type", sa.String(32), nullable=True))
    op.add_column("groups", sa.Column("avatar_url", sa.String(512), nullable=True))
    op.add_column("groups", sa.Column("cover_photo_url", sa.String(512), nullable=True))
    op.add_column("expenses", sa.Column("splitwise_receipt_url", sa.String(512), nullable=True))
    op.add_column("expenses", sa.Column("repayments", JSONB, nullable=True))


def downgrade() -> None:
    op.drop_column("expenses", "repayments")
    op.drop_column("expenses", "splitwise_receipt_url")
    op.drop_column("groups", "cover_photo_url")
    op.drop_column("groups", "avatar_url")
    op.drop_column("groups", "group_type")
