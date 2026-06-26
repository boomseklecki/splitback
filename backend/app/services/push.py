"""Fire-and-forget APNs dispatch for app notifications. No-op unless APNs is configured."""
import asyncio
import logging

import httpx
from sqlalchemy import delete, select

from app.config import settings
from app.db import async_session
from app.integrations.apns import sender
from app.models import DeviceToken

log = logging.getLogger(__name__)


def enqueue(owners: set[str], title: str, body: str) -> None:
    """Schedules a best-effort push to the owners' devices, without blocking the request."""
    if not settings.apns_configured or not owners:
        return
    asyncio.create_task(_send(set(owners), title, body))


async def _send(owners: set[str], title: str, body: str) -> None:
    try:
        async with async_session() as session:
            tokens = list(await session.scalars(
                select(DeviceToken).where(DeviceToken.user_identifier.in_(owners))))
            if not tokens:
                return
            dead: list[str] = []
            async with httpx.AsyncClient(http2=True, timeout=10) as client:
                for dt in tokens:
                    if await sender.send(client, dt.token, title, body):
                        dead.append(dt.token)
            if dead:
                await session.execute(delete(DeviceToken).where(DeviceToken.token.in_(dead)))
                await session.commit()
    except Exception:
        log.warning("push dispatch failed", exc_info=True)
