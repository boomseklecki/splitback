"""device tokens for APNs push

A `device_tokens` table mapping a user to their registered APNs device tokens.

Revision ID: 0036_device_tokens
Revises: 0035_sharing
Create Date: 2026-06-26

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0036_device_tokens"
down_revision: str | None = "0035_sharing"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "device_tokens",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("user_identifier", sa.String(128), nullable=False),
        sa.Column("token", sa.String(256), nullable=False),
        sa.Column("platform", sa.String(16), nullable=False, server_default="ios"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("user_identifier", "token", name="uq_device_token"),
    )
    op.create_index("ix_device_tokens_user", "device_tokens", ["user_identifier"])


def downgrade() -> None:
    op.drop_index("ix_device_tokens_user", table_name="device_tokens")
    op.drop_table("device_tokens")
