"""Ad-hoc: dump a Splitwise group's raw avatar/custom_avatar/type so we can see what the SDK returns.

Run inside the api container (no rebuild needed) by piping this file into its python:

    docker compose exec -T api python - < backend/scripts/inspect_sw_group.py

Optionally pass a group name (defaults to "Goehring Street") via env GROUP_NAME:

    docker compose exec -T -e GROUP_NAME="Key West" api python - < backend/scripts/inspect_sw_group.py
"""
import asyncio
import os

from sqlalchemy import select

from app.db import async_session
from app.integrations.splitwise import client as c
from app.models import SplitwiseToken

GROUP_NAME = os.environ.get("GROUP_NAME", "Goehring Street")


async def main() -> None:
    async with async_session() as session:
        token = (await session.scalars(select(SplitwiseToken))).first()
    if token is None:
        print("no splitwise token in DB")
        return

    cl = c.make_client(token.access_token)
    group = next((g for g in cl.getGroups() if g.getName() == GROUP_NAME), None)
    if group is None:
        print(f"group {GROUP_NAME!r} not found")
        return

    print("name:", group.getName())
    print("public attrs:", [a for a in dir(group) if not a.startswith("_")])
    print("group_type:", c._group_type(group))
    print("custom_avatar attr:", getattr(group, "custom_avatar", "MISSING"))
    print("getCustomAvatar callable:", callable(getattr(group, "getCustomAvatar", None)))
    print("_flag custom_avatar ->", c._flag(group, "custom_avatar", "getCustomAvatar"))

    avatar = c._method(group, "getAvatar")
    print("getAvatar() ->", repr(avatar), type(avatar).__name__)
    if avatar is not None:
        for m in ("getSmall", "getMedium", "getLarge", "getOriginal", "getXlarge", "getXxlarge"):
            print(f"   {m}:", c._method(avatar, m))
        print("   avatar public attrs:", [a for a in dir(avatar) if not a.startswith("_")])

    print("=> _avatar_url(group):", c._avatar_url(group))
    print("=> _cover_photo_url(group):", c._cover_photo_url(group))


asyncio.run(main())
