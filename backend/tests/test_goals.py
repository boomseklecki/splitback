"""Goals CRUD, account inclusion flags, and category-map manual mapping."""
import json
import urllib.error
import urllib.request

from sqlalchemy import delete, select

from app.db import async_session
from app.models import Account, Goal
from app.models.category_map import CategoryMap

API = "http://localhost:8000"
RAW = "Coffee Shop ZZZ"


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


async def test_spend_goal_crud_and_archive():
    goal_id = None
    try:
        status, body = _req("POST", "/goals", {
            "kind": "spend", "name": "Dining", "category": "Dining", "target_amount": "300.00",
        })
        assert status == 201, (status, body)
        goal_id = json.loads(body)["id"]
        assert any(g["id"] == goal_id for g in json.loads(_req("GET", "/goals")[1]))

        status, body = _req("PATCH", f"/goals/{goal_id}", {"target_amount": "250.00"})
        assert status == 200, (status, body)
        assert json.loads(body)["target_amount"] == "250.00"

        # Archive: gone from the default list, present with include_archived.
        assert _req("DELETE", f"/goals/{goal_id}")[0] == 204
        assert not any(g["id"] == goal_id for g in json.loads(_req("GET", "/goals")[1]))
        assert any(g["id"] == goal_id for g in json.loads(_req("GET", "/goals?include_archived=true")[1]))
    finally:
        if goal_id:
            async with async_session() as session:
                await session.execute(delete(Goal).where(Goal.id == goal_id))
                await session.commit()


async def test_account_inclusion_flags():
    account_id = None
    try:
        account_id = json.loads(_req("POST", "/accounts", {"name": "Brokerage ZZZ", "type": "investment"})[1])["id"]
        status, body = _req("PATCH", f"/accounts/{account_id}", {"include_in_spending": False})
        assert status == 200, (status, body)
        acc = json.loads(body)
        assert acc["include_in_spending"] is False and acc["include_in_cash_flow"] is None
        assert _req("DELETE", f"/accounts/{account_id}")[0] == 204
        account_id = None
    finally:
        if account_id:
            async with async_session() as session:
                await session.execute(delete(Account).where(Account.id == account_id))
                await session.commit()


async def test_account_display_name_and_kind_overrides():
    account_id = None
    try:
        account_id = json.loads(_req("POST", "/accounts", {"name": "CREDIT CARD ZZZ", "type": "credit card"})[1])["id"]

        # Set a display name + kind override.
        status, body = _req("PATCH", f"/accounts/{account_id}",
                            {"display_name": "Sapphire", "kind": "liability"})
        assert status == 200, (status, body)
        acc = json.loads(body)
        assert acc["display_name"] == "Sapphire" and acc["kind"] == "liability"
        # The Plaid `name` is untouched (the editor renders display_name ?? name).
        assert acc["name"] == "CREDIT CARD ZZZ"

        # Empty display_name resets to null (falls back to the Plaid name).
        acc = json.loads(_req("PATCH", f"/accounts/{account_id}", {"display_name": "  "})[1])
        assert acc["display_name"] is None and acc["kind"] == "liability"

        # An unknown kind is rejected.
        assert _req("PATCH", f"/accounts/{account_id}", {"kind": "bogus"})[0] == 422

        assert _req("DELETE", f"/accounts/{account_id}")[0] == 204
        account_id = None
    finally:
        if account_id:
            async with async_session() as session:
                await session.execute(delete(Account).where(Account.id == account_id))
                await session.commit()


async def test_category_map_upsert_sources():
    try:
        # An on-device suggestion, then a manual override of the same raw label.
        status, body = _req("PUT", "/category-map",
                            {"raw_category": RAW, "canonical_category": "Groceries", "source": "ondevice"})
        assert status == 200, (status, body)
        assert json.loads(body)["source"] == "ondevice"
        status, body = _req("PUT", "/category-map", {"raw_category": RAW, "canonical_category": "Dining"})
        assert status == 200, (status, body)
        row = json.loads(body)
        assert row["source"] == "manual" and row["canonical_category"] == "Dining"
        assert any(m["raw_category"] == RAW for m in json.loads(_req("GET", "/category-map")[1]))
        # Unknown canonical / source rejected.
        assert _req("PUT", "/category-map", {"raw_category": RAW, "canonical_category": "Nope"})[0] == 422
        assert _req("PUT", "/category-map",
                    {"raw_category": RAW, "canonical_category": "Dining", "source": "bogus"})[0] == 422
    finally:
        async with async_session() as session:
            await session.execute(delete(CategoryMap).where(CategoryMap.raw_category == RAW))
            await session.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
