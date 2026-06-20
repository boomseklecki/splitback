from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class CategoryMapUpsert(BaseModel):
    raw_category: str
    canonical_category: str
    source: str = "manual"  # "manual" (user pick) | "ondevice" (Apple Intelligence suggestion)


class CategoryMapResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    raw_category: str
    canonical_category: str
    source: str
    created_at: datetime
    updated_at: datetime
