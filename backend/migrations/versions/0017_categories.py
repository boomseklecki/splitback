"""editable categories table (seeded with the built-in taxonomy)

Revision ID: 0017_categories
Revises: 0016_txn_category_override
Create Date: 2026-06-20

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0017_categories"
down_revision: str | None = "0016_txn_category_override"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# The built-in taxonomy at this revision (inlined so the migration is self-contained, not coupled to app code).
CATEGORIES = [
    "Groceries", "Dining", "Transport", "Fuel", "Utilities", "Rent", "Mortgage", "Entertainment", "Travel",
    "Health", "Insurance", "Shopping", "Household", "Subscriptions", "Education", "Gifts", "Personal Care",
    "Pets", "Fees", "Income", "Transfer", "Settle-up", "Other",
]


def upgrade() -> None:
    categories = op.create_table(
        "categories",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("name", sa.String(64), nullable=False),
        sa.Column("builtin", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("position", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("icon", sa.String(64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("name", name="uq_categories_name"),
    )
    op.bulk_insert(
        categories,
        [{"name": name, "builtin": True, "position": i} for i, name in enumerate(CATEGORIES)],
    )


def downgrade() -> None:
    op.drop_table("categories")
