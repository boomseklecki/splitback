from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from app.models.enums import BackendType


class GroupCreate(BaseModel):
    name: str


class GroupUpdate(BaseModel):
    name: str | None = None
    hidden: bool | None = None


class GroupResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    backend_type: BackendType
    splitwise_group_id: str | None
    hidden: bool
    archived_at: datetime | None
    created_at: datetime
    updated_at: datetime
