"""user auth identity columns (apple/google sub, avatar)

Revision ID: 0007_user_auth
Revises: 0006_expense_archive
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0007_user_auth"
down_revision: str | None = "0006_expense_archive"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("users", sa.Column("apple_sub", sa.String(255), nullable=True))
    op.add_column("users", sa.Column("google_sub", sa.String(255), nullable=True))
    op.add_column("users", sa.Column("avatar_url", sa.String(512), nullable=True))
    op.create_unique_constraint("uq_users_apple_sub", "users", ["apple_sub"])
    op.create_unique_constraint("uq_users_google_sub", "users", ["google_sub"])


def downgrade() -> None:
    op.drop_constraint("uq_users_google_sub", "users", type_="unique")
    op.drop_constraint("uq_users_apple_sub", "users", type_="unique")
    op.drop_column("users", "avatar_url")
    op.drop_column("users", "google_sub")
    op.drop_column("users", "apple_sub")
