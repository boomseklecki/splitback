"""friends cache + generic notifications

Adds a `friends` table (cached Splitwise friend identity, independent of shared groups) and a generic
`notifications` table (`source: splitwise | app`) for the future in-app notification feature. Balances
stay live via /balances/friends; the friends table caches identity only.

Revision ID: 0031_friends_notifications
Revises: 0030_invites_and_enrollment
Create Date: 2026-06-25

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM, UUID

# Note: revision id kept <= 32 chars to fit Alembic's alembic_version.version_num (varchar(32)).
revision: str = "0031_friends_notifications"
down_revision: str | None = "0030_invites_and_enrollment"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "friends",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column("splitwise_friend_id", sa.String(64), nullable=False),
        sa.Column("identifier", sa.String(128), nullable=True),
        sa.Column("first_name", sa.String(255), nullable=True),
        sa.Column("last_name", sa.String(255), nullable=True),
        sa.Column("email", sa.String(255), nullable=True),
        sa.Column("avatar_url", sa.String(512), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("owner_identifier", "splitwise_friend_id", name="uq_friends_owner_friend"),
    )

    # create_type=False so create_table below doesn't try to re-create the type after this explicit create.
    notification_source = ENUM("splitwise", "app", name="notification_source", create_type=False)
    notification_source.create(op.get_bind(), checkfirst=True)
    op.create_table(
        "notifications",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column("source", notification_source, nullable=False),
        sa.Column("splitwise_id", sa.String(64), nullable=True),
        sa.Column("type", sa.String(32), nullable=True),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("read", sa.Boolean(), nullable=False, server_default=sa.text("false")),
    )
    op.create_index(
        "uq_notifications_owner_source_swid",
        "notifications",
        ["owner_identifier", "source", "splitwise_id"],
        unique=True,
        postgresql_where=sa.text("splitwise_id IS NOT NULL"),
    )

    # Seed the new server setting (mirrors app/server_settings.REGISTRY default).
    op.execute(
        "INSERT INTO server_settings (key, value) VALUES ('notifications_retention_count', '100') "
        "ON CONFLICT (key) DO NOTHING"
    )


def downgrade() -> None:
    op.execute("DELETE FROM server_settings WHERE key = 'notifications_retention_count'")
    op.drop_index("uq_notifications_owner_source_swid", table_name="notifications")
    op.drop_table("notifications")
    sa.Enum(name="notification_source").drop(op.get_bind(), checkfirst=True)
    op.drop_table("friends")
