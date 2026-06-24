import asyncio
import logging
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.auth import require_auth
from app.auth.scope import assert_owner
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

log = logging.getLogger(__name__)

router = APIRouter(prefix="/plaid", tags=["plaid"])


@router.post("/link-token", response_model=LinkTokenResponse)
async def create_link_token(
    body: LinkTokenRequest, caller: str | None = Depends(require_auth)
) -> LinkTokenResponse:
    # Link the bank under the authenticated caller; the body value is a back-compat hint used only in
    # open mode (no auth), never trusted when a session is present.
    owner = caller or body.user_identifier
    client = plaid_client.make_client()
    token = await asyncio.to_thread(client.create_link_token, owner)
    return LinkTokenResponse(link_token=token)


async def _create_item_from_public_token(
    session: AsyncSession, client, public_token: str, owner: str | None, institution_name: str | None
) -> UUID:
    """Exchange a public token, upsert the resulting PlaidItem + its accounts, and return the item id."""
    access_token, plaid_item_id = await asyncio.to_thread(client.exchange_public_token, public_token)
    # Prefer the client-supplied name, else resolve it from Plaid. Only ever set a non-null name so a
    # failed lookup never wipes an existing institution_name on conflict.
    institution_name = institution_name or await asyncio.to_thread(
        client.get_institution_name, access_token
    )
    values = {"plaid_item_id": plaid_item_id, "access_token": access_token, "user_identifier": owner}
    set_ = {"access_token": access_token, "user_identifier": owner}
    if institution_name:
        values["institution_name"] = institution_name
        set_["institution_name"] = institution_name

    item_id = (
        await session.execute(
            pg_insert(PlaidItem)
            .values(**values)
            .on_conflict_do_update(index_elements=[PlaidItem.plaid_item_id], set_=set_)
            .returning(PlaidItem.id)
        )
    ).scalar_one()

    # Resolve + cache the institution branding now, then denormalize it onto the accounts as we upsert them.
    item = await session.get(PlaidItem, item_id)
    await plaid_sync.resolve_institution(item, client)
    institution = {k: getattr(item, k) for k in plaid_sync._INSTITUTION_FIELDS}
    for account in await asyncio.to_thread(client.get_accounts, access_token):
        await plaid_sync._upsert_account(
            session, item_id, mapper.map_account(account), owner_identifier=owner, institution=institution
        )
    await session.commit()
    return item_id


@router.post("/exchange", response_model=ExchangeResponse)
async def exchange(
    body: ExchangeRequest,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> ExchangeResponse:
    owner = caller or body.user_identifier  # never trust the body's user_identifier when authenticated
    client = plaid_client.make_client()
    item_id = await _create_item_from_public_token(
        session, client, body.public_token, owner, body.institution_name
    )
    item = await session.get(PlaidItem, item_id)
    rows = await session.scalars(
        select(Account).where(Account.plaid_item_id == item_id).order_by(Account.created_at)
    )
    return ExchangeResponse(
        item_id=item_id, plaid_item_id=item.plaid_item_id, accounts=list(rows)
    )


@router.post("/sync", response_model=SyncResponse)
async def run_sync(
    body: SyncRequest | None = None,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> SyncResponse:
    stmt = select(PlaidItem)
    if caller is not None:
        stmt = stmt.where(PlaidItem.user_identifier == caller)
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
    synced = 0
    for item in items:
        # Isolate per-item failures: a single dead item (e.g. ITEM_NOT_FOUND after the bank was removed at
        # Plaid) must not abort the whole "Sync All Banks" — skip it and keep syncing the healthy ones.
        try:
            stats = await plaid_sync.sync_item(session, item, client)
        except Exception:
            await session.rollback()
            log.exception("Plaid sync failed for item %s (%s); skipping",
                          item.id, item.institution_name)
            continue
        synced += 1
        for key in totals:
            totals[key] += stats[key]
    # All items failed (e.g. every token revoked) — surface an error rather than a misleading success.
    if items and synced == 0:
        raise HTTPException(status_code=502, detail="No banks could be synced (all items failed at Plaid).")
    return SyncResponse(items_synced=synced, **totals)


@router.get("/items", response_model=list[PlaidItemResponse])
async def list_items(
    caller: str | None = Depends(require_auth), session: AsyncSession = Depends(get_session)
) -> list[PlaidItem]:
    stmt = select(PlaidItem).options(selectinload(PlaidItem.accounts))
    if caller is not None:
        stmt = stmt.where(PlaidItem.user_identifier == caller)
    rows = await session.scalars(stmt.order_by(PlaidItem.created_at))
    return list(rows)


@router.delete("/items/{item_id}", status_code=204)
async def delete_item(
    item_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    # Unlink: revoke the token at Plaid (best-effort), then delete locally — cascades the item's
    # accounts; their transactions keep with a null account_id.
    item = await session.get(PlaidItem, item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Plaid item not found")
    assert_owner(item.user_identifier, caller)
    try:
        await asyncio.to_thread(plaid_client.make_client().item_remove, item.access_token)
    except Exception:
        pass
    await session.delete(item)
    await session.commit()
