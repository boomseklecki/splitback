"""user splitwise registration status (confirmed/invited/dummy)

Revision ID: 0008_user_registration_status
Revises: 0007_user_auth
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0008_user_registration_status"
down_revision: str | None = "0007_user_auth"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("users", sa.Column("registration_status", sa.String(32), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "registration_status")
