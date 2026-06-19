from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class ReceiptResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    expense_id: UUID
    bucket: str
    object_key: str
    content_type: str | None
    created_at: datetime
