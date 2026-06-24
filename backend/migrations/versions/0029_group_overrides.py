"""per-(owner, group) override table

Moves the per-user `hidden` visibility toggle off the single `groups.hidden` column into a `group_overrides`
table keyed by `(owner_identifier, group_id)`, so two members of a shared group can hide it independently. The
shared/sourced group columns stay on `groups`. Groups have no single owner, so the backfill writes a row per
group member of each currently-hidden group (preserving "hidden for everyone who's a member"), then drops the
column.

Revision ID: 0029_group_overrides
Revises: 0028_account_overrides
Create Date: 2026-06-24

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

# Note: revision id kept <= 32 chars to fit Alembic's alembic_version.version_num (varchar(32)).
revision: str = "0029_group_overrides"
down_revision: str | None = "0028_account_overrides"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "group_overrides",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("owner_identifier", sa.String(128), nullable=False),
        sa.Column(
            "group_id", UUID(as_uuid=True),
            sa.ForeignKey("groups.id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("hidden", sa.Boolean(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("owner_identifier", "group_id", name="uq_group_override_owner_group"),
    )
    op.create_index("ix_group_override_owner", "group_overrides", ["owner_identifier"])
    op.create_index("ix_group_override_group", "group_overrides", ["group_id"])

    # Backfill: a hidden group was hidden for all its members, so write a row per member.
    op.execute(
        "INSERT INTO group_overrides (id, owner_identifier, group_id, hidden, created_at, updated_at) "
        "SELECT gen_random_uuid(), gm.user_identifier, g.id, true, now(), now() "
        "FROM groups g JOIN group_members gm ON gm.group_id = g.id "
        "WHERE g.hidden = true"
    )

    op.drop_column("groups", "hidden")


def downgrade() -> None:
    op.add_column(
        "groups",
        sa.Column("hidden", sa.Boolean(), nullable=False, server_default=sa.text("false")),
    )
    # Re-collapse to the shared column: hidden if any member hid it.
    op.execute(
        "UPDATE groups g SET hidden = true WHERE EXISTS ("
        "  SELECT 1 FROM group_overrides o WHERE o.group_id = g.id AND o.hidden = true)"
    )
    op.alter_column("groups", "hidden", server_default=None)
    op.drop_index("ix_group_override_group", table_name="group_overrides")
    op.drop_index("ix_group_override_owner", table_name="group_overrides")
    op.drop_table("group_overrides")
