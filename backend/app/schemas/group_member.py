from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class GroupMemberCreate(BaseModel):
    user_identifier: str


class GroupMemberResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    group_id: UUID
    user_identifier: str
    created_at: datetime
