from uuid import UUID

from pydantic import BaseModel, ConfigDict


class CategoryCreate(BaseModel):
    name: str
    icon: str | None = None


class CategoryUpdate(BaseModel):
    name: str | None = None
    icon: str | None = None


class CategoryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    builtin: bool
    position: int
    icon: str | None
