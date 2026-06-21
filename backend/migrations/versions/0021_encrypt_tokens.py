"""Encrypt Plaid/Splitwise access tokens at rest (Fernet)

Revision ID: 0021_encrypt_tokens
Revises: 0020_owner_scoping
Create Date: 2026-06-21

Widens the access_token columns to Text and, when ENCRYPTION_KEYS is configured, encrypts existing rows in
place (idempotent — already-encrypted values are skipped). No-op for the values when no key is set (dev).
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

from app.security.crypto import cipher

revision: str = "0021_encrypt_tokens"
down_revision: str | None = "0020_owner_scoping"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column("plaid_items", "access_token", type_=sa.Text())
    op.alter_column("splitwise_tokens", "access_token", type_=sa.Text())

    f = cipher()
    if f is None:
        return  # no key configured (dev) — leave values as-is
    bind = op.get_bind()
    for table in ("plaid_items", "splitwise_tokens"):
        rows = bind.execute(sa.text(f"SELECT id, access_token FROM {table}")).fetchall()
        for rid, token in rows:
            if token is None:
                continue
            try:  # skip rows that are already encrypted
                f.decrypt(token.encode())
                continue
            except Exception:
                pass
            bind.execute(
                sa.text(f"UPDATE {table} SET access_token = :t WHERE id = :id")
                .bindparams(t=f.encrypt(token.encode()).decode(), id=rid)
            )


def downgrade() -> None:
    # Values stay encrypted (no key handling on downgrade); just narrow the column types back.
    op.alter_column("splitwise_tokens", "access_token", type_=sa.String(length=512))
    op.alter_column("plaid_items", "access_token", type_=sa.String(length=256))
