from datetime import date as date_type
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from app.models.enums import TransactionSource


class TransactionCreate(BaseModel):
    account_id: UUID | None = None
    description: str
    amount: Decimal
    currency: str | None = None
    date: date_type
    category: str | None = None
    pending: bool = False


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
    pending: bool
    created_at: datetime
    updated_at: datetime
