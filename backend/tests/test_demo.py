"""Demo guest login (POST /auth/demo) + seed_identity. Drives the handler directly; toggles demo_mode in
process. Runs against the running Postgres; cleans up its own rows.
"""
from fastapi import HTTPException
from sqlalchemy import delete, func, select

from app.config import settings
from app.db import async_session
from app.integrations.dev_seed.seeder import seed_identity
from app.models import Account, Goal, Group, GroupMember, Transaction, User
from app.models.enums import UserSource
from app.routers.auth import auth_demo
from app.schemas.auth import DemoAuthRequest

FAKES = ["robin", "sam", "alex"]


async def _purge(session, identifier: str) -> None:
    gids = list(await session.scalars(
        select(GroupMember.group_id).where(GroupMember.user_identifier == identifier)))
    if gids:
        await session.execute(delete(Group).where(Group.id.in_(gids)))  # cascades expenses/splits
    for model in (Account, Transaction, Goal):
        await session.execute(delete(model).where(model.owner_identifier == identifier))
    await session.execute(delete(GroupMember).where(GroupMember.user_identifier == identifier))
    await session.execute(delete(User).where(User.identifier.in_([identifier, *FAKES])))
    await session.commit()


async def test_seed_identity_idempotent():
    ident = "seedid-zzz"
    async with async_session() as session:
        await _purge(session, ident)
        try:
            session.add(User(identifier=ident, display_name="Z", source=UserSource.app))
            await session.flush()
            assert await seed_identity(session, ident) is True
            await session.commit()
            assert await session.scalar(
                select(func.count()).select_from(Account).where(Account.owner_identifier == ident)) == 3
            assert await session.scalar(
                select(func.count()).select_from(GroupMember)
                .where(GroupMember.user_identifier == ident)) == 2
            async with async_session() as s2:
                assert await seed_identity(s2, ident) is False  # idempotent
        finally:
            await _purge(session, ident)


async def test_auth_demo_gated_and_seeds():
    saved = settings.demo_mode
    created: list[str] = []
    try:
        # Off everywhere but the demo backend.
        settings.demo_mode = False
        async with async_session() as session:
            try:
                await auth_demo(DemoAuthRequest(display_name="Casey"), session=session)
                assert False, "expected 404 when demo_mode off"
            except HTTPException as e:
                assert e.status_code == 404

        # On: guest gets a token + a populated isolated app.
        settings.demo_mode = True
        async with async_session() as session:
            resp = await auth_demo(DemoAuthRequest(display_name="Casey"), session=session)
            assert resp.token and resp.user.display_name == "Casey"
            assert resp.user.identifier.startswith("demo-")
            created.append(resp.user.identifier)
            assert await session.scalar(
                select(func.count()).select_from(Account)
                .where(Account.owner_identifier == resp.user.identifier)) == 3
    finally:
        settings.demo_mode = saved
        async with async_session() as session:
            for ident in created:
                await _purge(session, ident)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
