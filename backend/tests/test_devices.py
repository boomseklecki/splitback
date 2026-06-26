"""Device-token registration (idempotent + owner-scoped). The APNs sender now lives in the relay service."""
from fastapi import HTTPException
from sqlalchemy import delete, select

from app.db import async_session
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


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
