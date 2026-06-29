"""splitwise_tokens.notifications_pushed_at (push watermark)

A per-token high-water mark: the newest Splitwise notification `created_at` we've already accounted for
when deciding what to push. Push only items strictly newer than it, then advance it — so pruned-then-
refetched old notifications never re-push. Null until the first sync stamps it (cold start = no push).

Revision ID: 0043_notifications_pushed_at
Revises: 0042_notification_entity
Create Date: 2026-06-29

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0043_notifications_pushed_at"
down_revision: str | None = "0042_notification_entity"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("splitwise_tokens",
                  sa.Column("notifications_pushed_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("splitwise_tokens", "notifications_pushed_at")
