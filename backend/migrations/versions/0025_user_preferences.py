"""per-owner user preferences blob

Revision ID: 0025_user_preferences
Revises: 0024_institution_metadata
Create Date: 2026-06-24

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0025_user_preferences"
down_revision: str | None = "0024_institution_metadata"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "user_preferences",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column("key", sa.String(64), nullable=False),
        sa.Column("value", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("owner_identifier", "key", name="uq_user_preferences_owner_key"),
    )
    op.create_index("ix_user_preferences_owner_identifier", "user_preferences", ["owner_identifier"])


def downgrade() -> None:
    op.drop_index("ix_user_preferences_owner_identifier", table_name="user_preferences")
    op.drop_table("user_preferences")
