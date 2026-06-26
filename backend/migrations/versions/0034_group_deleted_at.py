"""groups.deleted_at — restorable Splitwise-group soft-delete

A Splitwise group deleted through the app keeps its shared row (+ members) flagged with `deleted_at` so any
member can restore it (Splitwise supports undelete). Self-hosted groups still hard-delete.

Revision ID: 0034_group_deleted_at
Revises: 0033_delete_include_overrides
Create Date: 2026-06-26

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# Note: revision id kept <= 32 chars to fit Alembic's alembic_version.version_num (varchar(32)).
revision: str = "0034_group_deleted_at"
down_revision: str | None = "0033_delete_include_overrides"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("groups", sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("groups", "deleted_at")
