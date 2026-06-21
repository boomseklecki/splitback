from datetime import date as date_type
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from app.models.enums import TransactionSource


class TransactionItemInput(BaseModel):
    id: UUID | None = None  # existing item to update in place (preserves added-by/on); null = new
    name: str
    quantity: Decimal = Decimal(1)
    price: Decimal
    category: str | None = None


class TransactionItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    quantity: Decimal
    price: Decimal
    category: str | None
    created_by: str | None
    updated_by: str | None
    created_at: datetime
    updated_at: datetime


class TransactionCreate(BaseModel):
    account_id: UUID | None = None
    description: str
    amount: Decimal
    currency: str | None = None
    date: date_type
    category: str | None = None
    pending: bool = False


class TransactionUpdate(BaseModel):
    # Per-transaction canonical category override; null clears it (revert to the label map/auto).
    category_override: str | None = None


class TransactionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    account_id: UUID | None
    plaid_transaction_id: str | None
    source: TransactionSource
    description: str
    amount: Decimal
    currency: str
    date: date_type
    category: str | None
    category_override: str | None
    pending: bool
    items: list[TransactionItemResponse] = []
    created_at: datetime
    updated_at: datetime
