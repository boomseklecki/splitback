"""group archive + hide flags

Revision ID: 0003_group_archive_hide
Revises: 0002_splitwise
Create Date: 2026-06-18

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0003_group_archive_hide"
down_revision: str | None = "0002_splitwise"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "groups",
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "groups",
        sa.Column("hidden", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade() -> None:
    op.drop_column("groups", "hidden")
    op.drop_column("groups", "archived_at")
