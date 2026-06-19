from pydantic import BaseModel

from app.schemas.user import UserResponse


class AppleAuthRequest(BaseModel):
    identity_token: str
    # Apple only sends the name on first consent; the client forwards it here when present.
    full_name: str | None = None


class GoogleAuthRequest(BaseModel):
    id_token: str


class AuthResponse(BaseModel):
    token: str
    user: UserResponse
