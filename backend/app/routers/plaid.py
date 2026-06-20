import asyncio
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.db import get_session
from app.integrations.plaid import client as plaid_client
from app.integrations.plaid import mapper
from app.integrations.plaid import sync as plaid_sync
from app.models import Account, PlaidItem
from app.schemas.plaid import (
    ExchangeRequest,
    ExchangeResponse,
    LinkTokenRequest,
    LinkTokenResponse,
    PlaidItemResponse,
    SyncRequest,
    SyncResponse,
)

router = APIRouter(prefix="/plaid", tags=["plaid"])


@router.post("/link-token", response_model=LinkTokenResponse)
async def create_link_token(body: LinkTokenRequest) -> LinkTokenResponse:
    client = plaid_client.make_client()
    token = await asyncio.to_thread(client.create_link_token, body.user_identifier)
    return LinkTokenResponse(link_token=token)


@router.post("/exchange", response_model=ExchangeResponse)
async def exchange(
    body: ExchangeRequest, session: AsyncSession = Depends(get_session)
) -> ExchangeResponse:
    client = plaid_client.make_client()
    access_token, plaid_item_id = await asyncio.to_thread(
        client.exchange_public_token, body.public_token
    )

    item_id = (
        await session.execute(
            pg_insert(PlaidItem)
            .values(
                plaid_item_id=plaid_item_id,
                access_token=access_token,
                institution_name=body.institution_name,
                user_identifier=body.user_identifier,
            )
            .on_conflict_do_update(
                index_elements=[PlaidItem.plaid_item_id],
                set_={
                    "access_token": access_token,
                    "institution_name": body.institution_name,
                    "user_identifier": body.user_identifier,
                },
            )
            .returning(PlaidItem.id)
        )
    ).scalar_one()

    accounts_raw = await asyncio.to_thread(client.get_accounts, access_token)
    for account in accounts_raw:
        await plaid_sync._upsert_account(session, item_id, mapper.map_account(account))
    await session.commit()

    rows = await session.scalars(
        select(Account).where(Account.plaid_item_id == item_id).order_by(Account.created_at)
    )
    return ExchangeResponse(
        item_id=item_id, plaid_item_id=plaid_item_id, accounts=list(rows)
    )


@router.post("/sync", response_model=SyncResponse)
async def run_sync(
    body: SyncRequest | None = None, session: AsyncSession = Depends(get_session)
) -> SyncResponse:
    stmt = select(PlaidItem)
    if body and body.item_id:
        stmt = stmt.where(PlaidItem.id == body.item_id)
    items = (await session.scalars(stmt)).all()
    if not items:
        raise HTTPException(status_code=404, detail="No Plaid items to sync")

    if body and body.reset:
        for item in items:
            item.transactions_cursor = None
        await session.flush()

    client = plaid_client.make_client()
    totals = {"accounts": 0, "added": 0, "modified": 0, "removed": 0}
    for item in items:
        stats = await plaid_sync.sync_item(session, item, client)
        for key in totals:
            totals[key] += stats[key]
    return SyncResponse(items_synced=len(items), **totals)


@router.get("/items", response_model=list[PlaidItemResponse])
async def list_items(session: AsyncSession = Depends(get_session)) -> list[PlaidItem]:
    rows = await session.scalars(
        select(PlaidItem).options(selectinload(PlaidItem.accounts)).order_by(PlaidItem.created_at)
    )
    return list(rows)


@router.delete("/items/{item_id}", status_code=204)
async def delete_item(item_id: UUID, session: AsyncSession = Depends(get_session)) -> None:
    # Local unlink: cascades the item's accounts; transactions keep with a null
    # account_id. Plaid-side /item/remove (to invalidate the token) is a TODO.
    item = await session.get(PlaidItem, item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Plaid item not found")
    await session.delete(item)
    await session.commit()
