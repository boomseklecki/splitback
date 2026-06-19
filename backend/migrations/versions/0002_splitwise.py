"""splitwise tokens, oauth states, group dedup index

Revision ID: 0002_splitwise
Revises: 0001_initial
Create Date: 2026-06-18

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0002_splitwise"
down_revision: str | None = "0001_initial"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "splitwise_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("user_identifier", sa.String(128), nullable=False),
        sa.Column("access_token", sa.String(512), nullable=False),
        sa.Column("token_type", sa.String(32), nullable=False, server_default="bearer"),
        sa.Column("scope", sa.String(256), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("user_identifier", name="uq_splitwise_tokens_user_identifier"),
    )

    op.create_table(
        "splitwise_oauth_states",
        sa.Column("state", sa.String(128), primary_key=True),
        sa.Column("code_verifier", sa.String(128), nullable=False),
        sa.Column("user_identifier", sa.String(128), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )

    # Idempotent group upsert keys off splitwise_group_id; self-hosted groups leave it null.
    op.create_index(
        "uq_groups_splitwise_group_id",
        "groups",
        ["splitwise_group_id"],
        unique=True,
        postgresql_where=sa.text("splitwise_group_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("uq_groups_splitwise_group_id", table_name="groups")
    op.drop_table("splitwise_oauth_states")
    op.drop_table("splitwise_tokens")
