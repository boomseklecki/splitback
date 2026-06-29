"""notifications.hidden (per-owner hide)

A per-owner "hide this row" flag: the owner swiped a notification away. Filtered from their feed and
preserved across Splitwise re-sync (the upsert never sets it). Each notification row is per-owner, so a
hide only affects that owner's feed.

Revision ID: 0044_notification_hidden
Revises: 0043_notifications_pushed_at
Create Date: 2026-06-29

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0044_notification_hidden"
down_revision: str | None = "0043_notifications_pushed_at"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("notifications",
                  sa.Column("hidden", sa.Boolean(), nullable=False, server_default=sa.text("false")))


def downgrade() -> None:
    op.drop_column("notifications", "hidden")
