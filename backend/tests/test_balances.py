"""Balance aggregation: per-group and overall (deleted groups excluded)."""
import json
import urllib.error
import urllib.request
from decimal import Decimal

from sqlalchemy import delete

from app.db import async_session
from app.models import Group, User
from app.models.enums import UserSource

API = "http://localhost:8000"
MATT = "bal-matt"
NIKKI = "bal-nikki"


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
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def _create_group(name):
    return json.loads(_req("POST", "/groups", {"name": name})[1])["id"]


def _create_expense(group_id, amount, splits):
    payload = {"group_id": group_id, "description": "x", "amount": amount, "date": "2023-01-01", "splits": splits}
    status, body = _req("POST", "/expenses", payload)
    assert status == 201, (status, body)


async def _cleanup(group_id):
    async with async_session() as session:
        await session.execute(delete(Group).where(Group.id == group_id))
        await session.execute(delete(User).where(User.identifier.in_([MATT, NIKKI])))
        await session.commit()


def _by_identifier(entries):
    return {e["identifier"]: e for e in entries}


async def test_group_and_overall_balances():
    group_id = _create_group("balances-test")
    try:
        async with async_session() as session:
            session.add(User(identifier=MATT, display_name="Matt", source=UserSource.app))
            await session.commit()

        # 40: matt paid all, split evenly
        _create_expense(group_id, "40.00", [
            {"user_identifier": MATT, "paid_share": "40.00", "owed_share": "20.00"},
            {"user_identifier": NIKKI, "paid_share": "0.00", "owed_share": "20.00"},
        ])
        # 10: nikki paid all, split evenly
        _create_expense(group_id, "10.00", [
            {"user_identifier": MATT, "paid_share": "0.00", "owed_share": "5.00"},
            {"user_identifier": NIKKI, "paid_share": "10.00", "owed_share": "5.00"},
        ])

        entries = _by_identifier(json.loads(_req("GET", f"/groups/{group_id}/balances")[1]))
        assert Decimal(str(entries[MATT]["net"])) == Decimal("15.00")
        assert Decimal(str(entries[NIKKI]["net"])) == Decimal("-15.00")
        assert entries[MATT]["display_name"] == "Matt"  # enriched from users
        assert entries[NIKKI]["display_name"] is None  # no users row
        # nets sum to zero
        assert sum(Decimal(str(e["net"])) for e in entries.values()) == Decimal("0.00")

        # overall includes them while active
        overall = _by_identifier(json.loads(_req("GET", "/balances")[1]))
        assert MATT in overall and NIKKI in overall

        # delete the group -> its expenses are gone, so it drops out of overall
        assert _req("DELETE", f"/groups/{group_id}")[0] == 204
        overall_after = _by_identifier(json.loads(_req("GET", "/balances")[1]))
        assert MATT not in overall_after and NIKKI not in overall_after
        # real delete (no soft-archive) -> the group itself is gone, so its balances 404
        assert _req("GET", f"/groups/{group_id}/balances")[0] == 404
    finally:
        await _cleanup(group_id)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
