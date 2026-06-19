"""Plaid sync: cursor pagination (fake fetcher), DB idempotency, and HTTP reads."""
import json
import urllib.request
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.plaid import sync as plaid_sync
from app.models import Account, PlaidItem, Transaction

API = "http://localhost:8000"
ITEM = "test-item-zzz"
ACC = "test-acc-zzz"
TX = "test-tx-zzz"


def _fake_fetcher(pages):
    state = {"i": 0}

    def fetch(access_token, cursor):
        page = pages[state["i"]]
        state["i"] += 1
        return page

    return fetch


def _accounts():
    return [{"plaid_account_id": ACC, "name": "Checking", "type": "checking", "balance": "100.00", "currency": "USD"}]


def _added():
    return [
        {
            "plaid_transaction_id": TX,
            "plaid_account_id": ACC,
            "description": "Coffee",
            "amount": "4.50",
            "currency": "USD",
            "date": "2023-03-01",
            "category": "Food",
            "pending": False,
        }
    ]


async def _cleanup():
    async with async_session() as session:
        await session.execute(delete(Transaction).where(Transaction.plaid_transaction_id == TX))
        await session.execute(delete(Account).where(Account.plaid_account_id == ACC))
        await session.execute(delete(PlaidItem).where(PlaidItem.plaid_item_id == ITEM))
        await session.commit()


def test_accumulate_sync_paginates():
    pages = [
        {"added": [{"plaid_transaction_id": "t1"}], "modified": [], "removed": [], "next_cursor": "c1", "has_more": True},
        {"added": [{"plaid_transaction_id": "t2"}], "modified": [{"plaid_transaction_id": "t3"}], "removed": ["r1"], "next_cursor": "c2", "has_more": False},
    ]
    result = plaid_sync.accumulate_sync(_fake_fetcher(pages), "token", None)
    assert [t["plaid_transaction_id"] for t in result["added"]] == ["t1", "t2"]
    assert [t["plaid_transaction_id"] for t in result["modified"]] == ["t3"]
    assert result["removed"] == ["r1"]
    assert result["cursor"] == "c2"


async def test_apply_sync_idempotent_and_removal():
    await _cleanup()
    try:
        async with async_session() as session:
            item = PlaidItem(plaid_item_id=ITEM, access_token="x")
            session.add(item)
            await session.commit()

            stats = await plaid_sync.apply_sync(
                session, item, _accounts(), {"added": _added(), "modified": [], "removed": [], "cursor": "c1"}
            )
            assert stats == {"accounts": 1, "added": 1, "modified": 0, "removed": 0}

            # re-apply same batch -> no duplicates, cursor advances
            await plaid_sync.apply_sync(
                session, item, _accounts(), {"added": _added(), "modified": [], "removed": [], "cursor": "c2"}
            )
            tx_count = await session.scalar(
                select(func.count()).select_from(Transaction).where(Transaction.plaid_transaction_id == TX)
            )
            acc_count = await session.scalar(
                select(func.count()).select_from(Account).where(Account.plaid_account_id == ACC)
            )
            assert tx_count == 1 and acc_count == 1
            assert item.transactions_cursor == "c2"
            balance = await session.scalar(select(Account.balance).where(Account.plaid_account_id == ACC))
            assert balance == Decimal("100.00")

            # removed id deletes the row
            await plaid_sync.apply_sync(
                session, item, _accounts(), {"added": [], "modified": [], "removed": [TX], "cursor": "c3"}
            )
            gone = await session.scalar(
                select(func.count()).select_from(Transaction).where(Transaction.plaid_transaction_id == TX)
            )
            assert gone == 0
    finally:
        await _cleanup()


async def test_accounts_and_transactions_http():
    await _cleanup()
    try:
        async with async_session() as session:
            item = PlaidItem(plaid_item_id=ITEM, access_token="x")
            session.add(item)
            await session.commit()
            await plaid_sync.apply_sync(
                session, item, _accounts(), {"added": _added(), "modified": [], "removed": [], "cursor": "c1"}
            )
            account_id = str(await session.scalar(select(Account.id).where(Account.plaid_account_id == ACC)))
            tx_id = str(await session.scalar(select(Transaction.id).where(Transaction.plaid_transaction_id == TX)))

        accounts = json.loads(urllib.request.urlopen(f"{API}/accounts").read())
        assert any(a["plaid_account_id"] == ACC for a in accounts)

        txs = json.loads(urllib.request.urlopen(f"{API}/transactions?account_id={account_id}").read())
        assert any(t["id"] == tx_id for t in txs)

        one = json.loads(urllib.request.urlopen(f"{API}/transactions/{tx_id}").read())
        assert one["plaid_transaction_id"] == TX and one["source"] == "plaid"
    finally:
        await _cleanup()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
