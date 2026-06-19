"""users directory + group members

Revision ID: 0005_users_members
Revises: 0004_plaid_items
Create Date: 2026-06-18

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005_users_members"
down_revision: str | None = "0004_plaid_items"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

user_source = postgresql.ENUM("app", "manual", "splitwise", name="user_source", create_type=False)


def upgrade() -> None:
    user_source.create(op.get_bind(), checkfirst=True)

    op.create_table(
        "users",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("identifier", sa.String(128), nullable=False),
        sa.Column("display_name", sa.String(255), nullable=False),
        sa.Column("source", user_source, nullable=False),
        sa.Column("splitwise_user_id", sa.String(64), nullable=True),
        sa.Column("email", sa.String(255), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("identifier", name="uq_users_identifier"),
    )

    op.create_table(
        "group_members",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("group_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("groups.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_identifier", sa.String(128), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("group_id", "user_identifier", name="uq_group_members_group_user"),
    )


def downgrade() -> None:
    op.drop_table("group_members")
    op.drop_table("users")
    user_source.drop(op.get_bind(), checkfirst=True)
