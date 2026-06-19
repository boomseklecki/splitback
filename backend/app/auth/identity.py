"""Find-or-create/link a User from a verified provider identity.

Called after a provider (apple/google/splitwise) token is verified. Idempotent: the same
provider sub always resolves to the same User; a matching email links a second provider onto
an existing User rather than creating a duplicate.
"""
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import User
from app.models.enums import UserSource
from app.utils import slugify

# Provider -> the User column holding that provider's subject id.
_PROVIDER_COLUMN = {
    "apple": "apple_sub",
    "google": "google_sub",
    "splitwise": "splitwise_user_id",
}


def _backfill(user: User, *, email: str | None, avatar: str | None) -> None:
    if user.email is None and email:
        user.email = email
    if user.avatar_url is None and avatar:
        user.avatar_url = avatar


async def _unique_identifier(session: AsyncSession, source_name: str) -> str:
    base = slugify(source_name)
    candidate, n = base, 1
    while await session.scalar(select(User.id).where(User.identifier == candidate)) is not None:
        n += 1
        candidate = f"{base}{n}"
    return candidate


async def resolve_user(
    session: AsyncSession,
    *,
    provider: str,
    sub: str,
    email: str | None,
    name: str | None,
    avatar: str | None,
) -> User:
    column = _PROVIDER_COLUMN[provider]

    # 1. Known provider sub -> that user.
    user = await session.scalar(select(User).where(getattr(User, column) == sub))
    if user is not None:
        _backfill(user, email=email, avatar=avatar)
        await session.commit()
        await session.refresh(user)
        return user

    # 2. Same email on an existing user -> link this provider onto it.
    if email:
        user = await session.scalar(select(User).where(User.email == email))
        if user is not None:
            setattr(user, column, sub)
            _backfill(user, email=email, avatar=avatar)
            await session.commit()
            await session.refresh(user)
            return user

    # 3. New user.
    identifier = await _unique_identifier(session, name or email or "user")
    user = User(
        identifier=identifier,
        display_name=name or email or identifier,
        source=UserSource.app,
        email=email,
        avatar_url=avatar,
    )
    setattr(user, column, sub)
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return user
