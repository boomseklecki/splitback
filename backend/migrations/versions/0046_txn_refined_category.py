"""add refined_category to transaction_overrides

The per-transaction on-device AI refinement (provenance .aiRefined) was device-only; sync it through the
existing per-(owner, transaction) override row so a non-AI-capable device inherits it. A separate column read
at a lower precedence rank than `category` — never conflated with the explicit user override.

Revision ID: 0046_txn_refined_category
Revises: 0045_category_tables
Create Date: 2026-06-30

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0046_txn_refined_category"
down_revision: str | None = "0045_category_tables"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("transaction_overrides", sa.Column("refined_category", sa.String(64), nullable=True))


def downgrade() -> None:
    op.drop_column("transaction_overrides", "refined_category")
