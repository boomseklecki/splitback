"""Phase 2: the `0047_categories_backfill` data migration parses `categories.v1` blobs into the relational
category tables. Seeds a good blob + a malformed one, rewinds to 0046, re-runs 0047, and asserts the good
owner's rows landed while the malformed blob was skipped (the migration didn't fail). Restores head.

Uses local NullPool engines (not the shared async_session) so the several `asyncio.run` calls here don't
collide with alembic's own internal `asyncio.run` over a shared, loop-bound engine.
"""
import asyncio
import json

from alembic import command
from alembic.config import Config
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy.pool import NullPool

from app.config import settings

OWNER_GOOD = "bf-good"
OWNER_BAD = "bf-bad"

_BLOB = json.dumps({
    "version": 1,
    "categories": [
        {"name": "Dining", "icon": "fork.knife", "position": 0, "builtin": True},
        {"name": "Surf", "icon": None, "position": 1, "builtin": False},
    ],
    "maps": [
        {"rawCategory": "FOOD_AND_DRINK", "canonicalCategory": "Dining", "source": "manual"},
        {"rawCategory": "GENERAL_SERVICES", "canonicalCategory": "Surf", "source": "ondevice"},
    ],
})


async def _run(stmts: list[tuple[str, dict]]):
    """Execute statements on a fresh disposable engine; return the rows of the last SELECT (if any)."""
    engine = create_async_engine(settings.database_url, poolclass=NullPool)
    result = None
    try:
        async with engine.begin() as conn:
            for sql, params in stmts:
                r = await conn.execute(text(sql), params)
                if r.returns_rows:
                    result = r.fetchall()
    finally:
        await engine.dispose()
    return result


def _clean():
    asyncio.run(_run([
        ("DELETE FROM spend_categories WHERE owner_identifier IN (:a, :b)", {"a": OWNER_GOOD, "b": OWNER_BAD}),
        ("DELETE FROM category_maps WHERE owner_identifier IN (:a, :b)", {"a": OWNER_GOOD, "b": OWNER_BAD}),
        ("DELETE FROM user_preferences WHERE owner_identifier IN (:a, :b)", {"a": OWNER_GOOD, "b": OWNER_BAD}),
    ]))


def test_categories_backfill_migration():
    cfg = Config("alembic.ini")
    _clean()
    asyncio.run(_run([
        ("INSERT INTO user_preferences (owner_identifier, key, value) VALUES (:o, 'categories.v1', :v)",
         {"o": OWNER_GOOD, "v": _BLOB}),
        ("INSERT INTO user_preferences (owner_identifier, key, value) VALUES (:o, 'categories.v1', :v)",
         {"o": OWNER_BAD, "v": "{ not valid json"}),
    ]))
    try:
        # Rewind past the backfill, then re-run it (0047.downgrade is a no-op, so version just resets).
        command.downgrade(cfg, "0046_txn_refined_category")
        command.upgrade(cfg, "0047_categories_backfill")

        cats = asyncio.run(_run([
            ("SELECT name FROM spend_categories WHERE owner_identifier = :o ORDER BY position",
             {"o": OWNER_GOOD})]))
        maps = asyncio.run(_run([
            ("SELECT raw_category, canonical_category, source FROM category_maps "
             "WHERE owner_identifier = :o ORDER BY raw_category", {"o": OWNER_GOOD})]))
        bad = asyncio.run(_run([
            ("SELECT count(*) FROM spend_categories WHERE owner_identifier = :o", {"o": OWNER_BAD})]))

        assert [r[0] for r in cats] == ["Dining", "Surf"]
        assert [tuple(r) for r in maps] == [
            ("FOOD_AND_DRINK", "Dining", "manual"),
            ("GENERAL_SERVICES", "Surf", "ondevice"),
        ]
        assert bad[0][0] == 0  # malformed blob skipped; migration completed
    finally:
        command.upgrade(cfg, "head")
        _clean()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
