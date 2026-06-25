"""server_settings registry: typed get/set round-trip + coercion; PATCH is admin-only and a reader reflects
the change. DB-backed."""
from fastapi import HTTPException
from sqlalchemy import delete

from app import server_settings
from app.auth import require_admin
from app.db import async_session
from app.models import User
from app.models.enums import UserSource
from app.routers.server_settings import update_server_settings
from app.schemas.server_settings import ServerSettingsUpdate

PREFIX = "sset-zzz"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(User).where(User.identifier.like(f"{PREFIX}%")))
        await s.commit()


async def test_set_get_roundtrip_and_coercion():
    async with async_session() as s:
        original = await server_settings.get(s, "sync_interval_hours")
    try:
        async with async_session() as s:
            await server_settings.set_value(s, "sync_interval_hours", 9)
            await s.commit()
        async with async_session() as s:
            assert await server_settings.get(s, "sync_interval_hours") == 9
        # A string value coerces to the registry int type.
        async with async_session() as s:
            await server_settings.set_value(s, "sync_interval_hours", "13")
            await s.commit()
        async with async_session() as s:
            assert await server_settings.get(s, "sync_interval_hours") == 13
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "sync_interval_hours", original)
            await s.commit()


async def test_patch_admin_gate_and_subset_update():
    await _purge()
    async with async_session() as s:
        s.add_all([
            User(identifier=f"{PREFIX}-admin", display_name="A", source=UserSource.app,
                 enrolled=True, is_admin=True),
            User(identifier=f"{PREFIX}-member", display_name="M", source=UserSource.app, enrolled=True),
        ])
        await s.commit()
        original = await server_settings.get(s, "groups_hard_delete_enabled")
    try:
        # require_admin forbids a non-admin member.
        async with async_session() as s:
            try:
                await require_admin(f"{PREFIX}-member", s)
                raise AssertionError("expected 403")
            except HTTPException as e:
                assert e.status_code == 403
        # An admin PATCH updates only the provided key; a reader reflects it.
        async with async_session() as s:
            resp = await update_server_settings(
                ServerSettingsUpdate(groups_hard_delete_enabled=True), caller=f"{PREFIX}-admin", session=s)
            assert resp.groups_hard_delete_enabled is True
        async with async_session() as s:
            assert await server_settings.get(s, "groups_hard_delete_enabled") is True
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "groups_hard_delete_enabled", original)
            await s.commit()
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
