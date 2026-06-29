"""notification_mutes (per-owner push/feed preferences)

Per-owner notification preferences as `"<channel>:<selector>"` tokens (channel = push|feed; selector = a
notification type code or `source:<src>`). The backend enforces `push:` tokens to suppress device push;
`feed:` tokens are persisted for the client to hide rows from its Inbox view. Feed rows are always written
regardless (audit log stays complete).

Revision ID: 0041_notification_prefs
Revises: 0040_pending_txn_id
Create Date: 2026-06-29

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0041_notification_prefs"
down_revision: str | None = "0040_pending_txn_id"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "notification_mutes",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column("token", sa.String(80), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("owner_identifier", "token", name="uq_notification_mutes_owner_token"),
    )
    op.create_index("ix_notification_mutes_owner_identifier", "notification_mutes", ["owner_identifier"])


def downgrade() -> None:
    op.drop_index("ix_notification_mutes_owner_identifier", table_name="notification_mutes")
    op.drop_table("notification_mutes")
