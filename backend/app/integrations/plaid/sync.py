"""Plaid transaction sync orchestration.

`accumulate_sync` (the cursor pagination loop) takes an injectable page-fetcher so
it can be tested with a fake; `apply_sync` does the DB upserts/deletes.
"""
import asyncio
from uuid import UUID

from sqlalchemy import delete
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.plaid import mapper
from app.models import Account, PlaidItem, Transaction, TransactionSource


def accumulate_sync(fetch_page, access_token: str, cursor: str | None) -> dict:
    """Page through /transactions/sync until has_more is false."""
    added: list[dict] = []
    modified: list[dict] = []
    removed: list[str] = []
    while True:
        page = fetch_page(access_token, cursor)
        added.extend(page["added"])
        modified.extend(page["modified"])
        removed.extend(page["removed"])
        cursor = page["next_cursor"]
        if not page["has_more"]:
            break
    return {"added": added, "modified": modified, "removed": removed, "cursor": cursor}


async def _upsert_account(
    session: AsyncSession, item_id: UUID, fields: dict, owner_identifier: str | None = None
) -> UUID:
    values = {**fields, "plaid_item_id": item_id, "owner_identifier": owner_identifier}
    update_cols = {
        k: values[k]
        for k in ("name", "type", "mask", "balance", "currency", "plaid_item_id", "owner_identifier")
    }
    stmt = (
        pg_insert(Account)
        .values(**values)
        .on_conflict_do_update(index_elements=[Account.plaid_account_id], set_=update_cols)
        .returning(Account.id)
    )
    return (await session.execute(stmt)).scalar_one()


async def _upsert_transaction(
    session: AsyncSession, account_map: dict, fields: dict, owner_identifier: str | None = None
) -> None:
    values = {
        "account_id": account_map.get(fields["plaid_account_id"]),
        "plaid_transaction_id": fields["plaid_transaction_id"],
        "source": TransactionSource.plaid,
        "description": fields["description"],
        "amount": fields["amount"],
        "currency": fields["currency"],
        "date": fields["date"],
        "category": fields["category"],
        "pending": fields["pending"],
        "owner_identifier": owner_identifier,
    }
    update_cols = {
        k: values[k]
        for k in ("account_id", "description", "amount", "currency", "date", "category",
                  "pending", "owner_identifier")
    }
    stmt = (
        pg_insert(Transaction)
        .values(**values)
        .on_conflict_do_update(
            index_elements=[Transaction.plaid_transaction_id], set_=update_cols
        )
    )
    await session.execute(stmt)


async def apply_sync(
    session: AsyncSession, item: PlaidItem, accounts: list[dict], sync_result: dict
) -> dict:
    account_map: dict[str, UUID] = {}
    for account in accounts:
        fields = mapper.map_account(account)
        account_map[fields["plaid_account_id"]] = await _upsert_account(
            session, item.id, fields, owner_identifier=item.user_identifier
        )

    for transaction in sync_result["added"] + sync_result["modified"]:
        await _upsert_transaction(
            session, account_map, mapper.map_transaction(transaction),
            owner_identifier=item.user_identifier,
        )

    if sync_result["removed"]:
        await session.execute(
            delete(Transaction).where(
                Transaction.plaid_transaction_id.in_(sync_result["removed"])
            )
        )

    item.transactions_cursor = sync_result["cursor"]
    await session.commit()
    return {
        "accounts": len(accounts),
        "added": len(sync_result["added"]),
        "modified": len(sync_result["modified"]),
        "removed": len(sync_result["removed"]),
    }


async def sync_item(session: AsyncSession, item: PlaidItem, client) -> dict:
    # Backfill the institution name for items linked before it was resolved (older links stored null,
    # which the app shows as "Bank"). Best-effort — leaves it null if the lookup fails.
    if not item.institution_name:
        name = await asyncio.to_thread(client.get_institution_name, item.access_token)
        if name:
            item.institution_name = name
    accounts = await asyncio.to_thread(client.get_accounts, item.access_token)
    sync_result = await asyncio.to_thread(
        accumulate_sync, client.fetch_transactions_page, item.access_token, item.transactions_cursor
    )
    return await apply_sync(session, item, accounts, sync_result)
