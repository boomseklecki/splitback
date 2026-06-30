"""goal_budget_notifications marker (fire budget push once per goal/month/threshold)

Lets the post-sync budget-push hook notify a goal owner once when their monthly spend crosses 85% (nearing)
or 100% (over), instead of re-firing every sync. Unique on (goal_id, period_month, kind).

Revision ID: 0048_goal_budget_notify
Revises: 0047_categories_backfill
Create Date: 2026-06-30

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0048_goal_budget_notify"
down_revision: str | None = "0047_categories_backfill"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "goal_budget_notifications",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column("goal_id", UUID(as_uuid=True),
                  sa.ForeignKey("goals.id", ondelete="CASCADE"), nullable=False),
        sa.Column("period_month", sa.Date(), nullable=False),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("goal_id", "period_month", "kind", name="uq_goal_budget_notif"),
    )
    op.create_index("ix_goal_budget_notif_owner", "goal_budget_notifications", ["owner_identifier"])
    op.create_index("ix_goal_budget_notif_goal", "goal_budget_notifications", ["goal_id"])


def downgrade() -> None:
    op.drop_index("ix_goal_budget_notif_goal", table_name="goal_budget_notifications")
    op.drop_index("ix_goal_budget_notif_owner", table_name="goal_budget_notifications")
    op.drop_table("goal_budget_notifications")
