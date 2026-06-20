from datetime import date as date_type
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class GoalCreate(BaseModel):
    kind: str  # "spend" | "save"
    name: str
    category: str | None = None
    account_id: UUID | None = None
    target_amount: Decimal
    save_target_type: str | None = None  # "balance" | "amount"
    starting_balance: Decimal | None = None
    starting_date: date_type | None = None
    period: str = "monthly"
    currency: str | None = None


class GoalUpdate(BaseModel):
    name: str | None = None
    category: str | None = None
    account_id: UUID | None = None
    target_amount: Decimal | None = None
    save_target_type: str | None = None
    starting_balance: Decimal | None = None
    starting_date: date_type | None = None
    period: str | None = None
    currency: str | None = None


class GoalResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    kind: str
    name: str
    category: str | None
    account_id: UUID | None
    target_amount: Decimal
    save_target_type: str | None
    starting_balance: Decimal | None
    starting_date: date_type | None
    period: str
    currency: str
    archived_at: datetime | None
    created_at: datetime
    updated_at: datetime
