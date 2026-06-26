"""Fire-and-forget push dispatch via the standalone relay (push.splitback.app). The backend holds no Apple
creds — it POSTs the device tokens + alert to the relay, which forwards to APNs and reports dead tokens.
No-op unless a relay URL + key are configured."""
import asyncio
import logging

import httpx
from sqlalchemy import delete, select

from app.config import settings
from app.db import async_session
from app.models import DeviceToken

log = logging.getLogger(__name__)


def enqueue(owners: set[str], title: str, body: str) -> None:
    """Schedules a best-effort push to the owners' devices, without blocking the request."""
    if not settings.push_configured or not owners:
        return
    asyncio.create_task(_send(set(owners), title, body))


async def _send(owners: set[str], title: str, body: str) -> None:
    try:
        async with async_session() as session:
            tokens = [dt.token for dt in await session.scalars(
                select(DeviceToken).where(DeviceToken.user_identifier.in_(owners)))]
            if not tokens:
                return
            dead: list[str] = []
            try:
                async with httpx.AsyncClient(timeout=10) as client:
                    resp = await client.post(
                        f"{settings.push_relay_url.rstrip('/')}/push",
                        headers={"Authorization": f"Bearer {settings.push_relay_api_key}"},
                        json={"tokens": tokens, "title": title, "body": body})
                if resp.status_code == 200:
                    dead = resp.json().get("dead", [])
            except Exception:
                log.warning("relay push failed", exc_info=True)
            if dead:
                await session.execute(delete(DeviceToken).where(DeviceToken.token.in_(dead)))
                await session.commit()
    except Exception:
        log.warning("push dispatch failed", exc_info=True)
