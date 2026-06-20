"""Two-way Splitwise write path: pure payload, token selection, SDK-mocked
orchestration, and HTTP guard rails. The live SDK call is monkeypatched — no
network. Full router->SDK success path is the documented manual end-to-end check.
"""
import json
import urllib.error
import urllib.request
from datetime import date
from decimal import Decimal

from sqlalchemy import delete

from app.db import async_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import writer
from app.models import BackendType, Expense, Group, Split, SplitwiseToken, User
from app.models.enums import UserSource

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


def _expense_dict(splits):
    return {"amount": Decimal("40.00"), "description": "Dinner", "currency": "USD", "date": "2023-05-01", "splits": splits}


# ---- pure payload ----

def test_build_payload():
    payload = writer.build_payload(
        _expense_dict([
            {"user_identifier": "matt", "paid_share": Decimal("40.00"), "owed_share": Decimal("20.00")},
            {"user_identifier": "nikki", "paid_share": Decimal("0"), "owed_share": Decimal("20.00")},
        ]),
        "123",
        {"matt": "11", "nikki": "22"},
    )
    assert payload["group_id"] == 123
    assert payload["cost"] == "40.00"
    assert {u["user_id"] for u in payload["users"]} == {"11", "22"}


def test_build_payload_marks_settleup_as_payment():
    swids = {"matt": "11", "nikki": "22"}
    splits = [
        {"user_identifier": "matt", "paid_share": Decimal("50.00"), "owed_share": Decimal("0")},
        {"user_identifier": "nikki", "paid_share": Decimal("0"), "owed_share": Decimal("50.00")},
    ]
    assert writer.build_payload(_expense_dict(splits), "1", swids)["payment"] is False
    settle = {**_expense_dict(splits), "category": "Settle-up"}
    assert writer.build_payload(settle, "1", swids)["payment"] is True


def test_build_payload_missing_swid():
    try:
        writer.build_payload(_expense_dict([{"user_identifier": "matt", "paid_share": Decimal("40"), "owed_share": Decimal("40")}]), "1", {})
    except KeyError as exc:
        assert exc.args[0] == "matt"
        return
    raise AssertionError("expected KeyError")


# ---- DB-backed helpers ----

async def _seed_expense(session, *, swid_users=True, splitwise_expense_id=None):
    if swid_users:
        session.add(User(identifier="pw-matt", display_name="M", source=UserSource.app, splitwise_user_id="11"))
        session.add(User(identifier="pw-nikki", display_name="N", source=UserSource.splitwise, splitwise_user_id="22"))
    group = Group(name="pw-g", backend_type=BackendType.splitwise, splitwise_group_id="500")
    session.add(group)
    await session.flush()
    expense = Expense(group_id=group.id, description="d", amount=Decimal("40.00"), currency="USD",
                      date=date(2023, 1, 1), splitwise_expense_id=splitwise_expense_id)
    expense.splits = [
        Split(user_identifier="pw-matt", paid_share=Decimal("40"), owed_share=Decimal("20")),
        Split(user_identifier="pw-nikki", paid_share=Decimal("0"), owed_share=Decimal("20")),
    ]
    session.add(expense)
    await session.commit()
    return group, expense


async def _purge():
    async with async_session() as session:
        await session.execute(delete(Group).where(Group.splitwise_group_id == "500"))
        await session.execute(delete(User).where(User.identifier.in_(["pw-matt", "pw-nikki"])))
        await session.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier.in_(["pw-matt", "anyone"])))
        await session.commit()


async def test_push_create_sets_id():
    await _purge()
    try:
        async with async_session() as session:
            group, expense = await _seed_expense(session)
            captured = {}

            def fake_create(client, payload):
                captured["p"] = payload
                return "sw-777"

            original = sw_client.create_expense
            sw_client.create_expense = fake_create
            try:
                sw_id = await writer.push_create(session, expense, group, object())
            finally:
                sw_client.create_expense = original
            assert sw_id == "sw-777" and expense.splitwise_expense_id == "sw-777"
            assert captured["p"]["group_id"] == 500
            assert {u["user_id"] for u in captured["p"]["users"]} == {"11", "22"}
    finally:
        await _purge()


async def test_push_update_calls_sdk():
    await _purge()
    try:
        async with async_session() as session:
            group, expense = await _seed_expense(session, splitwise_expense_id="sw-existing")
            captured = {}

            def fake_update(client, sw_id, payload):
                captured["id"] = sw_id
                return sw_id

            original = sw_client.update_expense
            sw_client.update_expense = fake_update
            try:
                result = await writer.push_update(session, expense, group, object())
            finally:
                sw_client.update_expense = original
            assert result == "sw-existing" and captured["id"] == "sw-existing"
    finally:
        await _purge()


async def test_push_delete_calls_sdk():
    captured = {}

    def fake_delete(client, sw_id):
        captured["id"] = sw_id

    original = sw_client.delete_expense
    sw_client.delete_expense = fake_delete
    try:
        await writer.push_delete(object(), "sw-del")
    finally:
        sw_client.delete_expense = original
    assert captured["id"] == "sw-del"


async def test_select_token_prefers_payer():
    await _purge()
    try:
        async with async_session() as session:
            group, expense = await _seed_expense(session)
            session.add(SplitwiseToken(user_identifier="pw-matt", access_token="tok-matt"))
            session.add(SplitwiseToken(user_identifier="anyone", access_token="tok-other"))
            await session.commit()
            token = await writer.select_token(session, expense)
            assert token.user_identifier == "pw-matt"  # payer (paid_share > 0)
    finally:
        await _purge()


async def test_push_guard_rails_http():
    sw_id = json.loads(_req("POST", "/groups", {"name": "pw-http"})[1])["id"]
    # turn it into a Splitwise group directly
    async with async_session() as session:
        from uuid import UUID
        grp = await session.get(Group, UUID(sw_id))
        grp.backend_type = BackendType.splitwise
        grp.splitwise_group_id = "900"
        await session.commit()
    try:
        balanced = [{"user_identifier": "pw-x", "paid_share": "10.00", "owed_share": "10.00"}]
        # no token stored -> 409
        assert _req("POST", "/expenses", {"group_id": sw_id, "description": "x", "amount": "10.00", "date": "2023-01-01", "splits": balanced})[0] == 409
        # token present but participant has no splitwise_user_id -> 422
        async with async_session() as session:
            session.add(SplitwiseToken(user_identifier="anyone", access_token="x"))
            await session.commit()
        assert _req("POST", "/expenses", {"group_id": sw_id, "description": "x", "amount": "10.00", "date": "2023-01-01", "splits": balanced})[0] == 422
    finally:
        async with async_session() as session:
            await session.execute(delete(Group).where(Group.id == __import__("uuid").UUID(sw_id)))
            await session.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier == "anyone"))
            await session.commit()


def test_status_and_import_without_token():
    status = json.loads(_req("GET", "/splitwise/status")[1])
    assert status["connected"] is False
    assert _req("POST", "/splitwise/import", {"dry_run": True})[0] == 400


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
