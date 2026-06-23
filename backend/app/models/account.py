import uuid
from decimal import Decimal

from sqlalchemy import Boolean, ForeignKey, Numeric, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Account(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "accounts"

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    # User-set display name overriding Plaid's `name`; null = show `name`. Survives re-sync (Plaid sync
    # only updates name/type/balance/currency — see plaid/sync.py _upsert_account).
    display_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Plaid account type/subtype (e.g. depository/checking); free-form for now
    type: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # User-set classification override ("cash_flow" | "liability" | "savings"); null = derive from `type`.
    # Survives re-sync like the inclusion flags below.
    kind: Mapped[str | None] = mapped_column(String(16), nullable=True)
    # The account number's last few digits (Plaid `mask`), for display on the account row; null for manual.
    mask: Mapped[str | None] = mapped_column(String(32), nullable=True)
    plaid_account_id: Mapped[str | None] = mapped_column(String(128), unique=True, nullable=True)
    # Set for Plaid-linked accounts; null for manual ones
    plaid_item_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("plaid_items.id", ondelete="CASCADE"), nullable=True
    )
    balance: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False, default=0)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="USD")
    # The local identifier this account belongs to (per-caller scoping). For Plaid accounts this is the
    # linker (plaid_items.user_identifier); for manual accounts, the creator. Null = legacy/unowned.
    owner_identifier: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # User overrides for Goals analytics; null = derive from the account's classification (subtype).
    include_in_spending: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    include_in_cash_flow: Mapped[bool | None] = mapped_column(Boolean, nullable=True)

    plaid_item: Mapped["PlaidItem | None"] = relationship(  # noqa: F821
        back_populates="accounts"
    )
    transactions: Mapped[list["Transaction"]] = relationship(  # noqa: F821
        back_populates="account"
    )
