from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.db import get_session
from app.models import User
from app.models.enums import UserSource
from app.schemas.user import MeResponse, UserCreate, UserResponse, UserUpdate
from app.utils import ensure_utc, slugify

router = APIRouter(tags=["users"])


@router.get("/me", response_model=MeResponse)
async def me(
    identifier: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> MeResponse:
    user = None
    if identifier is not None:
        user = await session.scalar(select(User).where(User.identifier == identifier))
    return MeResponse(identifier=identifier, authenticated=identifier is not None, user=user)


@router.get("/users", response_model=list[UserResponse])
async def list_users(
    source: UserSource | None = None,
    updated_since: datetime | None = None,
    session: AsyncSession = Depends(get_session),
) -> list[User]:
    stmt = select(User)
    if source is not None:
        stmt = stmt.where(User.source == source)
    if updated_since is not None:
        stmt = stmt.where(User.updated_at >= ensure_utc(updated_since))
    rows = await session.scalars(stmt.order_by(User.display_name))
    return list(rows)


@router.post("/users", response_model=UserResponse, status_code=201)
async def create_user(
    body: UserCreate, session: AsyncSession = Depends(get_session)
) -> User:
    identifier = body.identifier or slugify(body.display_name)
    if await session.scalar(select(User).where(User.identifier == identifier)):
        raise HTTPException(status_code=409, detail=f"identifier '{identifier}' already exists")
    user = User(
        identifier=identifier,
        display_name=body.display_name,
        source=body.source,
        splitwise_user_id=body.splitwise_user_id,
        email=body.email,
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return user


@router.get("/users/{user_id}", response_model=UserResponse)
async def get_user(user_id: UUID, session: AsyncSession = Depends(get_session)) -> User:
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return user


@router.patch("/users/{user_id}", response_model=UserResponse)
async def update_user(
    user_id: UUID, body: UserUpdate, session: AsyncSession = Depends(get_session)
) -> User:
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if body.display_name is not None:
        user.display_name = body.display_name
    if body.email is not None:
        user.email = body.email
    await session.commit()
    await session.refresh(user)
    return user


@router.delete("/users/{user_id}", status_code=204)
async def delete_user(user_id: UUID, session: AsyncSession = Depends(get_session)) -> None:
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    await session.delete(user)
    await session.commit()
