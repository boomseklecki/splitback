"""collapse per-level refresh thresholds into per-provider (plaid/splitwise)

Replaces the four pull-to-refresh level thresholds (list/detail/leaf/item) with two provider thresholds —
Plaid (paid, sync less often) and Splitwise (free). The old keys were never seeded by a migration; they
only exist as a row if an admin PATCHed one, so the DELETE is defensive.

Revision ID: 0032_refresh_provider_thresholds
Revises: 0031_friends_notifications
Create Date: 2026-06-25

"""
from collections.abc import Sequence

from alembic import op

# Note: revision id kept <= 32 chars to fit Alembic's alembic_version.version_num (varchar(32)).
revision: str = "0032_refresh_provider_thresholds"
down_revision: str | None = "0031_friends_notifications"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_OLD_KEYS = (
    "refresh_list_stale_minutes",
    "refresh_detail_stale_minutes",
    "refresh_leaf_stale_minutes",
    "refresh_item_stale_minutes",
)


def upgrade() -> None:
    keys = ", ".join(f"'{k}'" for k in _OLD_KEYS)
    op.execute(f"DELETE FROM server_settings WHERE key IN ({keys})")
    op.execute(
        "INSERT INTO server_settings (key, value) VALUES "
        "('refresh_plaid_stale_minutes', '60'), ('refresh_splitwise_stale_minutes', '15') "
        "ON CONFLICT (key) DO NOTHING"
    )


def downgrade() -> None:
    op.execute(
        "DELETE FROM server_settings "
        "WHERE key IN ('refresh_plaid_stale_minutes', 'refresh_splitwise_stale_minutes')"
    )
    op.execute(
        "INSERT INTO server_settings (key, value) VALUES "
        "('refresh_list_stale_minutes', '30'), ('refresh_detail_stale_minutes', '15'), "
        "('refresh_leaf_stale_minutes', '0'), ('refresh_item_stale_minutes', '5') "
        "ON CONFLICT (key) DO NOTHING"
    )
