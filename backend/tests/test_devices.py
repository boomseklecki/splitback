"""Device-token registration (idempotent + owner-scoped) and the APNs provider-JWT builder."""
import base64

import jwt as pyjwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException
from sqlalchemy import delete, select

from app.config import settings
from app.db import async_session
from app.integrations.apns import sender
from app.models import DeviceToken
from app.routers.devices import register_device, unregister_device
from app.schemas.device import DeviceRegister

ALICE = "dev-alice"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(DeviceToken).where(DeviceToken.user_identifier == ALICE))
        await s.commit()


async def _count() -> int:
    async with async_session() as s:
        return len(list(await s.scalars(
            select(DeviceToken).where(DeviceToken.user_identifier == ALICE))))


async def test_register_idempotent():
    await _purge()
    try:
        for _ in range(2):
            async with async_session() as s:
                await register_device(DeviceRegister(token="tok-1"), caller=ALICE, session=s)
        assert await _count() == 1
    finally:
        await _purge()


async def test_unregister_removes():
    await _purge()
    try:
        async with async_session() as s:
            await register_device(DeviceRegister(token="tok-x"), caller=ALICE, session=s)
        async with async_session() as s:
            await unregister_device(DeviceRegister(token="tok-x"), caller=ALICE, session=s)
        assert await _count() == 0
    finally:
        await _purge()


async def test_register_requires_auth():
    async with async_session() as s:
        try:
            await register_device(DeviceRegister(token="t"), caller=None, session=s)
            raise AssertionError("expected 401")
        except HTTPException as e:
            assert e.status_code == 401


async def test_apns_provider_token_builds():
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption())
    saved = (settings.apns_key_id, settings.apns_team_id, settings.apns_auth_key)
    sender._token_cache = None
    settings.apns_key_id, settings.apns_team_id = "KID123", "TEAM123"
    settings.apns_auth_key = base64.b64encode(pem).decode()
    try:
        header = pyjwt.get_unverified_header(sender._provider_token())
        assert header["alg"] == "ES256" and header["kid"] == "KID123"
    finally:
        settings.apns_key_id, settings.apns_team_id, settings.apns_auth_key = saved
        sender._token_cache = None


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
