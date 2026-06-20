"""goals table (spend budgets + savings goals)

Revision ID: 0014_goals
Revises: 0013_category_map
Create Date: 2026-06-19

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0014_goals"
down_revision: str | None = "0013_category_map"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "goals",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("name", sa.String(128), nullable=False),
        sa.Column("category", sa.String(64), nullable=True),
        sa.Column(
            "account_id",
            UUID(as_uuid=True),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            nullable=True,
        ),
        sa.Column("target_amount", sa.Numeric(12, 2), nullable=False),
        sa.Column("save_target_type", sa.String(16), nullable=True),
        sa.Column("starting_balance", sa.Numeric(12, 2), nullable=True),
        sa.Column("starting_date", sa.Date(), nullable=True),
        sa.Column("period", sa.String(16), nullable=False, server_default="monthly"),
        sa.Column("currency", sa.String(3), nullable=False, server_default="USD"),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("goals")
