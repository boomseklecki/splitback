"""notification entity_type/entity_id (deep-link target)

App-native notifications gain a target reference so the Inbox row and a tapped push can route to the
underlying entity. `entity_id` holds a UUID string (expense/account/goal/group) or a friend identifier
(connections); both nullable (Splitwise-synced rows have none).

Revision ID: 0042_notification_entity
Revises: 0041_notification_prefs
Create Date: 2026-06-29

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0042_notification_entity"
down_revision: str | None = "0041_notification_prefs"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("notifications", sa.Column("entity_type", sa.String(32), nullable=True))
    op.add_column("notifications", sa.Column("entity_id", sa.String(128), nullable=True))


def downgrade() -> None:
    op.drop_column("notifications", "entity_id")
    op.drop_column("notifications", "entity_type")
