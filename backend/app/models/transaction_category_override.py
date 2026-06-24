import uuid

from sqlalchemy import ForeignKey, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class TransactionCategoryOverride(UUIDMixin, TimestampMixin, Base):
    """A user's canonical-category override for one transaction, keyed by `(owner_identifier,
    transaction_id)` so it's per-user — independent overrides survive a future shared transaction (e.g. a
    shared bank account viewed by two users). The app applies it over the local label map. Plaid sync never
    touches it (it lives in its own table)."""

    __tablename__ = "transaction_category_overrides"
    __table_args__ = (
        UniqueConstraint("owner_identifier", "transaction_id", name="uq_txn_override_owner_txn"),
    )

    owner_identifier: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    transaction_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("transactions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    category: Mapped[str] = mapped_column(String(128), nullable=False)
