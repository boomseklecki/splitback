import uuid
from datetime import date as date_type
from decimal import Decimal

from sqlalchemy import Boolean, Date, Enum, ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.models.enums import TransactionSource


class Transaction(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "transactions"

    account_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="SET NULL"), nullable=True
    )
    # Dedup key for Plaid-sourced rows; null for manual entries
    plaid_transaction_id: Mapped[str | None] = mapped_column(
        String(128), unique=True, nullable=True
    )
    source: Mapped[TransactionSource] = mapped_column(
        Enum(TransactionSource, name="transaction_source"), nullable=False
    )
    description: Mapped[str] = mapped_column(String(512), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    date: Mapped[date_type] = mapped_column(Date, nullable=False)
    category: Mapped[str | None] = mapped_column(String(128), nullable=True)
    pending: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    account: Mapped["Account | None"] = relationship(  # noqa: F821
        back_populates="transactions"
    )
