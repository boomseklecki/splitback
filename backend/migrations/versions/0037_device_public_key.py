"""device token public key for E2E push

Adds a nullable `public_key` (base64 X9.63 P-256) to `device_tokens` so the backend can seal push
payloads to a device's key (ECIES) and keep the relay blind to content.

Revision ID: 0037_device_public_key
Revises: 0036_device_tokens
Create Date: 2026-06-26

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0037_device_public_key"
down_revision: str | None = "0036_device_tokens"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("device_tokens", sa.Column("public_key", sa.String(128), nullable=True))


def downgrade() -> None:
    op.drop_column("device_tokens", "public_key")
