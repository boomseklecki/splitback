from datetime import date as date_type
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from app.schemas.receipt import ReceiptResponse


class SplitInput(BaseModel):
    user_identifier: str
    paid_share: Decimal
    owed_share: Decimal


class ItemInput(BaseModel):
    name: str
    quantity: Decimal = Decimal(1)
    price: Decimal
    category: str | None = None


class ExpenseCreate(BaseModel):
    group_id: UUID
    description: str
    amount: Decimal
    currency: str | None = None
    date: date_type
    category: str | None = None
    transaction_id: UUID | None = None
    splits: list[SplitInput] = []
    items: list[ItemInput] = []


class ExpenseUpdate(BaseModel):
    group_id: UUID | None = None
    description: str | None = None
    amount: Decimal | None = None
    currency: str | None = None
    date: date_type | None = None
    category: str | None = None
    transaction_id: UUID | None = None
    splits: list[SplitInput] | None = None
    items: list[ItemInput] | None = None


class SplitResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_identifier: str
    paid_share: Decimal
    owed_share: Decimal


class ItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    quantity: Decimal
    price: Decimal
    category: str | None


class ExpenseResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    group_id: UUID
    transaction_id: UUID | None
    splitwise_expense_id: str | None
    description: str
    amount: Decimal
    currency: str
    date: date_type
    category: str | None
    created_by: str | None
    updated_by: str | None
    splitwise_created_at: datetime | None
    splitwise_updated_at: datetime | None
    notes: str | None
    comments_count: int | None
    repeats: bool | None
    repeat_interval: str | None
    expense_bundle_id: str | None
    splitwise_receipt_url: str | None
    repayments: list | None
    archived_at: datetime | None
    created_at: datetime
    updated_at: datetime
    splits: list[SplitResponse] = []
    items: list[ItemResponse] = []
    receipts: list[ReceiptResponse] = []
