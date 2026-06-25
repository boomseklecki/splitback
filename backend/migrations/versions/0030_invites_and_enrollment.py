"""invites + DB-backed enrollment + server-settings store

Replaces the `.env` enroll allowlist with DB-backed enrollment: adds `users.enrolled` / `users.is_admin`,
an `invites` table (single-use codes), an `invite` column on `splitwise_oauth_states`, and a `server_settings`
key/value store. Backfills `enrolled=true` for already-signed-in users and seeds `server_settings` from the
current env values (so prod policy carries over) using only stdlib `os` (no app imports).

Revision ID: 0030_invites_and_enrollment
Revises: 0029_group_overrides
Create Date: 2026-06-24

"""
import json
import os
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

# Note: revision id kept <= 32 chars to fit Alembic's alembic_version.version_num (varchar(32)).
revision: str = "0030_invites_and_enrollment"
down_revision: str | None = "0029_group_overrides"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# key -> (env var, kind, default). Mirrors app/server_settings.REGISTRY; kept inline so the migration is
# self-contained (no app import). `invites_open_to_members` has no env source (defaults false).
_SETTINGS: dict[str, tuple[str | None, str, object]] = {
    "invites_open_to_members": (None, "bool", False),
    "public_hostname": ("PUBLIC_HOSTNAME", "str", ""),
    "groups_hard_delete_enabled": ("GROUPS_HARD_DELETE_ENABLED", "bool", False),
    "expenses_hard_delete_enabled": ("EXPENSES_HARD_DELETE_ENABLED", "bool", False),
    "splitwise_receipt_download_enabled": ("SPLITWISE_RECEIPT_DOWNLOAD_ENABLED", "bool", False),
    "sync_interval_hours": ("SYNC_INTERVAL_HOURS", "int", 0),
    "backup_interval_hours": ("BACKUP_INTERVAL_HOURS", "int", 0),
    "backups_retention_days": ("BACKUPS_RETENTION_DAYS", "int", 30),
    "backups_retention_min_keep": ("BACKUPS_RETENTION_MIN_KEEP", "int", 7),
}


def _env_value(env: str | None, kind: str, default: object) -> object:
    raw = os.getenv(env) if env else None
    if raw is None or raw == "":
        return default
    if kind == "bool":
        return raw.strip().lower() in {"1", "true", "yes", "on"}
    if kind == "int":
        try:
            return int(raw)
        except ValueError:
            return default
    return raw


def upgrade() -> None:
    op.create_table(
        "invites",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("code", sa.String(64), nullable=False),
        sa.Column("created_by", sa.String(128), nullable=False),
        sa.Column("label", sa.String(255), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("redeemed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("redeemed_by", sa.String(128), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_invites_code", "invites", ["code"], unique=True)

    op.create_table(
        "server_settings",
        sa.Column("key", sa.String(64), primary_key=True),
        sa.Column("value", sa.Text(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )

    op.add_column("users", sa.Column("enrolled", sa.Boolean(), nullable=False, server_default=sa.text("false")))
    op.add_column("users", sa.Column("is_admin", sa.Boolean(), nullable=False, server_default=sa.text("false")))
    op.add_column("splitwise_oauth_states", sa.Column("invite", sa.String(64), nullable=True))

    # Grandfather everyone who has actually signed in (provider-linked or app-native); Splitwise/manual
    # contact rows stay un-enrolled — they need an invite to log in.
    op.execute(
        "UPDATE users SET enrolled = true "
        "WHERE google_sub IS NOT NULL OR apple_sub IS NOT NULL OR source = 'app'"
    )
    op.alter_column("users", "enrolled", server_default=None)
    op.alter_column("users", "is_admin", server_default=None)

    # Seed server_settings from the current env so prod policy carries over.
    settings_table = sa.table(
        "server_settings", sa.column("key", sa.String), sa.column("value", sa.Text)
    )
    op.bulk_insert(
        settings_table,
        [
            {"key": key, "value": json.dumps(_env_value(env, kind, default))}
            for key, (env, kind, default) in _SETTINGS.items()
        ],
    )


def downgrade() -> None:
    op.drop_column("splitwise_oauth_states", "invite")
    op.drop_column("users", "is_admin")
    op.drop_column("users", "enrolled")
    op.drop_table("server_settings")
    op.drop_index("ix_invites_code", table_name="invites")
    op.drop_table("invites")
