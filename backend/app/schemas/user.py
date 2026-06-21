from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from app.models.enums import UserSource


class UserCreate(BaseModel):
    display_name: str
    identifier: str | None = None  # derived from display_name when omitted
    source: UserSource = UserSource.manual
    splitwise_user_id: str | None = None
    email: str | None = None


class UserUpdate(BaseModel):
    display_name: str | None = None
    email: str | None = None


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    identifier: str
    display_name: str
    source: UserSource
    splitwise_user_id: str | None
    email: str | None
    avatar_url: str | None
    registration_status: str | None
    created_at: datetime
    updated_at: datetime


class MeResponse(BaseModel):
    identifier: str | None
    authenticated: bool
    is_admin: bool = False
    user: UserResponse | None
