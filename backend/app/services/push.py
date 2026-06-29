"""Fire-and-forget push dispatch via the standalone relay (push.splitback.app). The backend holds no Apple
creds — it POSTs to the relay, which forwards to APNs and reports dead tokens. No-op unless a relay URL + key
are configured.

Devices that have published a P-256 public key (`DeviceToken.public_key`) get an **E2E-encrypted** push: the
content is sealed to that key (see `crypto_push.seal`) and only ciphertext transits the relay (it forwards a
generic "New activity" fallback alert + the ciphertext for the on-device Notification Service Extension to
decrypt). Devices without a key fall back to the plaintext form (older builds). When the relay enforces
`RELAY_REQUIRE_E2EE`, the plaintext call is simply rejected and those devices get no push — acceptable once
every build publishes a key."""
import asyncio
import base64
import logging

import httpx
from sqlalchemy import delete, select

from app.config import settings
from app.db import async_session
from app.models import DeviceToken
from app.services import crypto_push

log = logging.getLogger(__name__)

_FALLBACK_TITLE = "SplitBack"
_FALLBACK_BODY = "New activity"


def enqueue(owners: set[str], title: str, body: str, target: dict | None = None) -> None:
    """Schedules a best-effort push to the owners' devices, without blocking the request. `target` is an
    optional deep-link payload ({type, id}) sealed into the E2E push for the tap handler to route on."""
    if not settings.push_configured or not owners:
        return
    asyncio.create_task(_send(set(owners), title, body, target))


async def _post(client: httpx.AsyncClient, payload: dict) -> list[str]:
    """POSTs one push request to the relay; returns dead tokens (empty on any failure)."""
    try:
        resp = await client.post(
            f"{settings.push_relay_url.rstrip('/')}/push",
            headers={"Authorization": f"Bearer {settings.push_relay_api_key}"},
            json=payload)
        if resp.status_code == 200:
            return resp.json().get("dead", [])
    except Exception:
        log.warning("relay push failed", exc_info=True)
    return []


async def _send(owners: set[str], title: str, body: str, target: dict | None = None) -> None:
    try:
        async with async_session() as session:
            devices = list(await session.scalars(
                select(DeviceToken).where(DeviceToken.user_identifier.in_(owners))))
            if not devices:
                return
            messages, plain_tokens = [], []
            for dt in devices:
                if dt.public_key:
                    try:
                        sealed = crypto_push.seal(title, body, base64.b64decode(dt.public_key), target=target)
                        messages.append({"token": dt.token, **sealed})
                        continue
                    except Exception:
                        log.warning("seal failed; falling back to plaintext", exc_info=True)
                plain_tokens.append(dt.token)

            dead: list[str] = []
            async with httpx.AsyncClient(timeout=10) as client:
                if messages:
                    dead += await _post(client, {"messages": messages,
                                                 "fallback_title": _FALLBACK_TITLE,
                                                 "fallback_body": _FALLBACK_BODY})
                if plain_tokens:
                    dead += await _post(client, {"tokens": plain_tokens, "title": title, "body": body})

            if dead:
                await session.execute(delete(DeviceToken).where(DeviceToken.token.in_(dead)))
                await session.commit()
    except Exception:
        log.warning("push dispatch failed", exc_info=True)
