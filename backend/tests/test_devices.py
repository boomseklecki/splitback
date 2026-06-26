"""Device-token registration (idempotent + owner-scoped) and relay dispatch. The APNs sender lives in the
relay; devices with a published public key get an E2E-encrypted (relay-blind) push, others plaintext."""
import base64

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException
from sqlalchemy import delete, select

from app.config import settings
from app.db import async_session
from app.models import DeviceToken
from app.routers.devices import register_device, unregister_device
from app.schemas.device import DeviceRegister
from app.services import push

ALICE = "dev-alice"


def _pubkey_b64() -> str:
    pub = ec.generate_private_key(ec.SECP256R1()).public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return base64.b64encode(pub).decode()


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


async def test_register_stores_and_rotates_public_key():
    await _purge()
    try:
        key1, key2 = _pubkey_b64(), _pubkey_b64()
        async with async_session() as s:
            await register_device(DeviceRegister(token="tok-k", public_key=key1), caller=ALICE, session=s)
        async with async_session() as s:
            dt = await s.scalar(select(DeviceToken).where(DeviceToken.user_identifier == ALICE))
            assert dt.public_key == key1
        async with async_session() as s:  # re-register with a rotated key updates it
            await register_device(DeviceRegister(token="tok-k", public_key=key2), caller=ALICE, session=s)
        async with async_session() as s:
            dt = await s.scalar(select(DeviceToken).where(DeviceToken.user_identifier == ALICE))
            assert dt.public_key == key2 and await _count() == 1
    finally:
        await _purge()


class _FakeResp:
    def __init__(self, dead): self._dead = dead
    status_code = 200
    def json(self): return {"dead": self._dead}


class _FakeClient:
    """Captures relay POSTs; reports the plaintext token as dead so we exercise cleanup."""
    calls: list[dict] = []

    def __init__(self, *a, **k): pass
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False

    async def post(self, url, headers=None, json=None):
        _FakeClient.calls.append(json)
        return _FakeResp(json.get("tokens", []))  # report plaintext tokens dead so we exercise pruning


async def test_push_seals_for_keyed_devices_plaintext_otherwise():
    await _purge()
    orig_url, orig_key, orig_cls = (settings.push_relay_url, settings.push_relay_api_key, push.httpx.AsyncClient)
    settings.push_relay_url, settings.push_relay_api_key = "http://relay.test", "k"
    push.httpx.AsyncClient = _FakeClient
    _FakeClient.calls = []
    try:
        async with async_session() as s:
            s.add(DeviceToken(user_identifier=ALICE, token="tok-keyed", public_key=_pubkey_b64()))
            s.add(DeviceToken(user_identifier=ALICE, token="tok-plain"))
            await s.commit()
        await push._send({ALICE}, "SplitBack", "Alice added 'Dinner'")

        enc = next(c for c in _FakeClient.calls if "messages" in c)
        plain = next(c for c in _FakeClient.calls if "tokens" in c)
        assert enc["messages"][0]["token"] == "tok-keyed"
        assert {"epk", "box"} <= set(enc["messages"][0])
        assert "Dinner" not in str(enc)                       # content never leaves in cleartext
        assert plain["tokens"] == ["tok-plain"] and plain["body"] == "Alice added 'Dinner'"

        async with async_session() as s:                      # dead plaintext token pruned
            left = {dt.token for dt in await s.scalars(
                select(DeviceToken).where(DeviceToken.user_identifier == ALICE))}
        assert left == {"tok-keyed"}
    finally:
        settings.push_relay_url, settings.push_relay_api_key = orig_url, orig_key
        push.httpx.AsyncClient = orig_cls
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
