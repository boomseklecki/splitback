"""DELETE /expenses behavior matrix:

- local-only expense        -> archive (default), no Splitwise touch
- Splitwise-linked, active   -> propagate to Splitwise (default); ?propagate=false archives
- Splitwise-linked, archived -> archive locally (default); ?propagate=true propagates

The Splitwise propagation paths have no token stored, so they short-circuit to 409 before any
live SDK call — which is exactly what proves "propagation was attempted, not archived".
"""
import json
import urllib.error
import urllib.request
from datetime import date, datetime, timezone
from decimal import Decimal

from sqlalchemy import delete

from app.db import async_session
from app.models import BackendType, Expense, Group, Split

API = "http://localhost:8000"


def _req(method, path, data=None):
    headers = {}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=body, method=method, headers=headers)
    try:
        resp = urllib.request.urlopen(req)
        return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


async def _purge(group_id):
    async with async_session() as session:
        await session.execute(delete(Group).where(Group.id == group_id))
        await session.commit()


async def _seed_sw_expense(group_archived: bool, sw_group_id: str):
    async with async_session() as session:
        group = Group(
            name="arc-sw",
            backend_type=BackendType.splitwise,
            splitwise_group_id=sw_group_id,
            archived_at=datetime.now(timezone.utc) if group_archived else None,
        )
        session.add(group)
        await session.flush()
        expense = Expense(group_id=group.id, description="x", amount=Decimal("10.00"), currency="USD",
                          date=date(2023, 1, 1), splitwise_expense_id=f"sw-{sw_group_id}")
        expense.splits = [Split(user_identifier="arc-x", paid_share=Decimal("10"), owed_share=Decimal("10"))]
        session.add(expense)
        await session.commit()
        return group.id, str(expense.id)


def _archived_at(expense_id):
    return json.loads(_req("GET", f"/expenses/{expense_id}")[1])["archived_at"]


async def test_local_expense_archive_default():
    gid = json.loads(_req("POST", "/groups", {"name": "archive-test"})[1])["id"]
    try:
        eid = json.loads(_req("POST", "/expenses", {
            "group_id": gid, "description": "x", "amount": "40.00", "date": "2023-01-01",
            "splits": [
                {"user_identifier": "arc-matt", "paid_share": "40.00", "owed_share": "20.00"},
                {"user_identifier": "arc-nikki", "paid_share": "0.00", "owed_share": "20.00"},
            ],
        })[1])["id"]

        assert _req("DELETE", f"/expenses/{eid}")[0] == 204
        assert _archived_at(eid) is not None
        # gone from default list + balances, visible with include_archived
        assert not any(e["id"] == eid for e in json.loads(_req("GET", f"/expenses?group_id={gid}")[1]))
        assert any(e["id"] == eid for e in json.loads(_req("GET", f"/expenses?group_id={gid}&include_archived=true")[1]))
        assert json.loads(_req("GET", f"/groups/{gid}/balances")[1]) == []
    finally:
        await _purge(gid)


async def test_sw_active_group_propagates_by_default():
    gid, eid = await _seed_sw_expense(False, "6201")
    try:
        # active Splitwise group, no token -> propagation attempted -> 409, NOT archived
        assert _req("DELETE", f"/expenses/{eid}")[0] == 409
        assert _archived_at(eid) is None
    finally:
        await _purge(gid)


async def test_sw_active_group_force_archive():
    gid, eid = await _seed_sw_expense(False, "6202")
    try:
        assert _req("DELETE", f"/expenses/{eid}?propagate=false")[0] == 204
        assert _archived_at(eid) is not None
    finally:
        await _purge(gid)


async def test_sw_archived_group_archives_by_default():
    gid, eid = await _seed_sw_expense(True, "6203")
    try:
        assert _req("DELETE", f"/expenses/{eid}")[0] == 204
        assert _archived_at(eid) is not None
    finally:
        await _purge(gid)


async def test_sw_archived_group_force_propagate():
    gid, eid = await _seed_sw_expense(True, "6204")
    try:
        # force propagate even though group archived -> attempts Splitwise -> 409 (no token)
        assert _req("DELETE", f"/expenses/{eid}?propagate=true")[0] == 409
        assert _archived_at(eid) is None
    finally:
        await _purge(gid)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
