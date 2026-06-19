"""Sign-in endpoints: verify a provider token, find-or-create the user, issue our JWT.

Mounted UNGUARDED — these establish the session the rest of the API is guarded by.
"""
import asyncio

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import tokens
from app.auth.identity import resolve_user
from app.db import get_session
from app.integrations.auth import ProviderVerificationError, apple, google
from app.schemas.auth import AppleAuthRequest, AuthResponse, GoogleAuthRequest
from app.schemas.user import UserResponse

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/apple", response_model=AuthResponse)
async def auth_apple(
    body: AppleAuthRequest, session: AsyncSession = Depends(get_session)
) -> AuthResponse:
    try:
        claims = await asyncio.to_thread(apple.verify_identity_token, body.identity_token)
    except ProviderVerificationError as exc:
        raise HTTPException(status_code=401, detail="Invalid Apple identity token") from exc
    user = await resolve_user(
        session,
        provider="apple",
        sub=claims["sub"],
        email=claims.get("email"),
        name=body.full_name,
        avatar=None,
    )
    return AuthResponse(token=tokens.issue(user), user=UserResponse.model_validate(user))


@router.post("/google", response_model=AuthResponse)
async def auth_google(
    body: GoogleAuthRequest, session: AsyncSession = Depends(get_session)
) -> AuthResponse:
    try:
        claims = await asyncio.to_thread(google.verify_id_token, body.id_token)
    except ProviderVerificationError as exc:
        raise HTTPException(status_code=401, detail="Invalid Google ID token") from exc
    user = await resolve_user(
        session,
        provider="google",
        sub=claims["sub"],
        email=claims.get("email"),
        name=claims.get("name"),
        avatar=claims.get("picture"),
    )
    return AuthResponse(token=tokens.issue(user), user=UserResponse.model_validate(user))
