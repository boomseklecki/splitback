"""The Splitwise group upsert bumps `groups.updated_at` on the conflict path, so it tracks the last sync —
the freshness signal the app's smart-refresh thresholds read. DB-backed."""
import asyncio

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.splitwise.importer import _upsert_group
from app.models import Group

SWID = "sw-grp-zzz"


async def _cleanup(session):
    await session.execute(delete(Group).where(Group.splitwise_group_id == SWID))
    await session.commit()


async def test_upsert_group_bumps_updated_at():
    async with async_session() as s:
        await _cleanup(s)
        try:
            gid = await _upsert_group(s, SWID, "Trip")
            await s.commit()
            first = await s.scalar(select(Group.updated_at).where(Group.id == gid))

            await asyncio.sleep(0.05)  # ensure a later transaction clock so now() advances
            await _upsert_group(s, SWID, "Trip")  # conflict → DO UPDATE
            await s.commit()
            second = await s.scalar(select(Group.updated_at).where(Group.id == gid))

            assert second > first  # the upsert advanced updated_at even though nothing changed
        finally:
            await _cleanup(s)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
