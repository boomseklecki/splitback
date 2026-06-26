"""partner connections + per-account share level + goal shared flag

Zeta-style sharing v1: a `connections` table (mutually-accepted partner link), an owner-set `share_level` on
accounts (private/balances/full), and a `shared` flag on goals.

Revision ID: 0035_sharing
Revises: 0034_group_deleted_at
Create Date: 2026-06-26

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ENUM, UUID

# Note: revision id kept <= 32 chars to fit Alembic's alembic_version.version_num (varchar(32)).
revision: str = "0035_sharing"
down_revision: str | None = "0034_group_deleted_at"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    connection_status = ENUM("pending", "accepted", name="connection_status", create_type=False)
    connection_status.create(op.get_bind(), checkfirst=True)
    op.create_table(
        "connections",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("requester_identifier", sa.String(128), nullable=False),
        sa.Column("addressee_identifier", sa.String(128), nullable=False),
        sa.Column("status", connection_status, nullable=False, server_default="pending"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("requester_identifier", "addressee_identifier", name="uq_connection_pair"),
    )
    op.create_index("ix_connections_requester", "connections", ["requester_identifier"])
    op.create_index("ix_connections_addressee", "connections", ["addressee_identifier"])

    share_level = ENUM("private", "balances", "full", name="share_level", create_type=False)
    share_level.create(op.get_bind(), checkfirst=True)
    op.add_column("accounts", sa.Column(
        "share_level", share_level, nullable=False, server_default="private"))

    op.add_column("goals", sa.Column(
        "shared", sa.Boolean(), nullable=False, server_default=sa.text("false")))


def downgrade() -> None:
    op.drop_column("goals", "shared")
    op.drop_column("accounts", "share_level")
    sa.Enum(name="share_level").drop(op.get_bind(), checkfirst=True)
    op.drop_index("ix_connections_addressee", table_name="connections")
    op.drop_index("ix_connections_requester", table_name="connections")
    op.drop_table("connections")
    sa.Enum(name="connection_status").drop(op.get_bind(), checkfirst=True)
