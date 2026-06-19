from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class AccountCreate(BaseModel):
    name: str
    type: str | None = None
    balance: Decimal = Decimal(0)
    currency: str | None = None


class AccountResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    type: str | None
    plaid_account_id: str | None
    balance: Decimal
    currency: str
    created_at: datetime
    updated_at: datetime
