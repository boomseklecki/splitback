"""retire the legacy categories.v1 preferences blob

Phase 5 of the category-aware work. Categories now live in the relational `spend_categories` + `category_maps`
tables (migrations 0045/0047); the `categories.v1` preferences blob was kept only as a transition fallback
while clients cut over to `GET/PUT /categories`. With the relational-sync iOS build adopted, the blob is dead
weight — delete those `user_preferences` rows. Other preference keys (suggestions.v1, order, link-sensitivity)
are untouched.

Non-destructive in practice: the data already lives relationally (0047 backfilled it). `downgrade` is a no-op
— we never recreate user data on downgrade.

Revision ID: 0049_drop_categories_blob
Revises: 0048_goal_budget_notify
Create Date: 2026-06-30

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0049_drop_categories_blob"
down_revision: str | None = "0048_goal_budget_notify"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(sa.text("DELETE FROM user_preferences WHERE key = 'categories.v1'"))


def downgrade() -> None:
    # Intentional no-op: the categories are authoritative in spend_categories/category_maps; there's nothing
    # to restore and we must not recreate deleted user data.
    pass
