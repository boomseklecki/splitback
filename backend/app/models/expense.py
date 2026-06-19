import uuid
from datetime import date as date_type
from datetime import datetime
from decimal import Decimal

from sqlalchemy import Date, DateTime, ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Expense(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "expenses"

    group_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("groups.id", ondelete="CASCADE"), nullable=False
    )
    # Optional link to the originating Plaid/manual transaction
    transaction_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("transactions.id", ondelete="SET NULL"), nullable=True
    )
    # Dedup key for Splitwise-synced rows; null for self-hosted-only expenses
    splitwise_expense_id: Mapped[str | None] = mapped_column(
        String(64), unique=True, nullable=True
    )
    description: Mapped[str] = mapped_column(String(512), nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    date: Mapped[date_type] = mapped_column(Date, nullable=False)
    category: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # Who added the expense (user_identifier, from Splitwise created_by); null for self-hosted.
    created_by: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # Splitwise receipt image URL (remote, not our proxied bytes) + simplified repayments, both from import.
    splitwise_receipt_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    repayments: Mapped[list | None] = mapped_column(JSONB, nullable=True)
    # Soft-delete marker; null = active (DELETE archives unless hard-delete is enabled)
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    group: Mapped["Group"] = relationship(back_populates="expenses")  # noqa: F821
    items: Mapped[list["ExpenseItem"]] = relationship(  # noqa: F821
        back_populates="expense", cascade="all, delete-orphan"
    )
    splits: Mapped[list["Split"]] = relationship(  # noqa: F821
        back_populates="expense", cascade="all, delete-orphan"
    )
    receipts: Mapped[list["Receipt"]] = relationship(  # noqa: F821
        back_populates="expense", cascade="all, delete-orphan"
    )
