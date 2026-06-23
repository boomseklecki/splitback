"""Auth dependency for app-facing endpoints.

Accepts our own session JWT (verified -> user identifier) or, for back-compat, a static
`API_TOKENS` entry. Default-open: with no credentials and enforcement off the dependency is a
pass-through, so local dev and tests work unchanged. Enforcement (401 on a missing/invalid
credential) turns on when `AUTH_REQUIRED` is set or any `API_TOKENS` are configured. Health,
the `/auth/*` sign-in endpoints, and the Splitwise OAuth login/callback are left unguarded.
"""
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import tokens
from app.auth.access import is_admin, is_allowed
from app.config import settings
from app.db import get_session
from app.models import User

_bearer = HTTPBearer(auto_error=False)


async def require_auth(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    session: AsyncSession = Depends(get_session),
) -> str | None:
    """Returns the caller's identifier, or None in open mode."""
    token = credentials.credentials if credentials else None
    if token:
        user_id = tokens.verify(token)
        if user_id is not None:
            user = await session.get(User, user_id)
            if user is not None:
                # Re-check the allowlist every request so removing someone takes effect immediately
                # (their existing JWT stops working), not only at sign-in.
                if not is_allowed(email=None, user=user):
                    raise HTTPException(
                        status_code=status.HTTP_403_FORBIDDEN,
                        detail="This account isn't permitted on this server.",
                    )
                return user.identifier
        identifier = settings.api_tokens.get(token)  # operator-configured static tokens bypass the allowlist
        if identifier is not None:
            return identifier

    if settings.auth_required or settings.api_tokens:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing credentials",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return None


async def require_admin(caller: str | None = Depends(require_auth)) -> str:
    """Gate for operator-only endpoints (e.g. backups): the caller must resolve to a configured admin
    (`ADMIN_USERS`). 403 otherwise. In open mode (no caller) this still forbids — admin actions always
    require an identified admin."""
    if not is_admin(caller):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin only")
    return caller  # type: ignore[return-value]  # is_admin(None) is False, so caller is non-None here
