"""Build a per-user category preferences blob from the (legacy, now-shared) `categories` + `category_map`
tables and upsert it into `user_preferences`, so a user keeps their existing custom categories/maps after the
move to local-authoritative categories.

The blob matches the iOS `CategorySnapshot` shape (camelCase map keys), stored under key `categories.v1`.

Run inside the api container AFTER deploying migration 0025 (which creates `user_preferences`):

    docker compose exec -T api python - matt < backend/scripts/seed_category_prefs.py

Pass one or more `owner_identifier`s as args (or `SEED_OWNERS=matt,nikki`). Pass `--dry-run` to print the
blob without writing. Idempotent: re-running overwrites the same (owner, key) row.
"""
import asyncio
import json
import os
import sys

from sqlalchemy import select

from app.db import async_session
from app.models import Category, CategoryMap, UserPreference

KEY = "categories.v1"


async def build_snapshot(session) -> str:
    cats = (await session.scalars(select(Category).order_by(Category.position, Category.name))).all()
    maps = (await session.scalars(select(CategoryMap).order_by(CategoryMap.raw_category))).all()
    snapshot = {
        "version": 1,
        "categories": [
            {"name": c.name, "icon": c.icon, "position": c.position, "builtin": c.builtin} for c in cats
        ],
        "maps": [
            {"rawCategory": m.raw_category, "canonicalCategory": m.canonical_category, "source": m.source}
            for m in maps
        ],
    }
    return json.dumps(snapshot, separators=(",", ":"), ensure_ascii=False)


async def main(owners: list[str], dry_run: bool) -> None:
    async with async_session() as session:
        value = await build_snapshot(session)
        parsed = json.loads(value)
        print(f"snapshot: {len(parsed['categories'])} categories, {len(parsed['maps'])} maps, "
              f"{len(value)} bytes")
        if dry_run:
            print(value)
            return
        for owner in owners:
            row = await session.scalar(
                select(UserPreference).where(
                    UserPreference.owner_identifier == owner, UserPreference.key == KEY
                )
            )
            if row is None:
                row = UserPreference(owner_identifier=owner, key=KEY)
                session.add(row)
            row.value = value
            print(f"  upserted {KEY} for owner={owner!r}")
        await session.commit()


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "-"]
    dry_run = "--dry-run" in args
    owners = [a for a in args if not a.startswith("--")] or [
        o for o in os.environ.get("SEED_OWNERS", "").split(",") if o
    ]
    if not owners and not dry_run:
        print("usage: seed_category_prefs.py <owner_identifier> [more...] [--dry-run]")
        sys.exit(1)
    asyncio.run(main(owners, dry_run))
