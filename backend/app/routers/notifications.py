from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.auth.scope import assert_owner
from app.db import get_session
from app.models import Notification
from app.schemas.splitwise import NotificationResponse

router = APIRouter(tags=["notifications"])


@router.get("/notifications", response_model=list[NotificationResponse])
async def list_notifications(
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Notification]:
    """The caller's notifications across all sources (Splitwise + app), newest first."""
    stmt = select(Notification).order_by(Notification.created_at.desc())
    if caller is not None:
        stmt = stmt.where(Notification.owner_identifier == caller)
    return list(await session.scalars(stmt))


@router.post("/notifications/{notification_id}/read", response_model=NotificationResponse)
async def mark_read(
    notification_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Notification:
    """Marks a notification read (owner only)."""
    notification = await session.get(Notification, notification_id)
    if notification is None:
        raise HTTPException(status_code=404, detail="Notification not found")
    assert_owner(notification.owner_identifier, caller)
    notification.read = True
    await session.commit()
    await session.refresh(notification)
    return notification
