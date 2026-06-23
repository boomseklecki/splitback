"""All-tenant data sync (Plaid + Splitwise), for the periodic scheduler.

Mirrors what the app's refresh buttons do, but server-side and for every linked item/token, with no request
context. Per-item/per-token failures are isolated and logged so one bad integration doesn't abort the rest.
"""
import logging
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.integrations.plaid import client as plaid_client
from app.integrations.plaid import sync as plaid_sync
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import importer
from app.models import PlaidItem, SplitwiseToken

log = logging.getLogger(__name__)


async def sync_all_plaid(session: AsyncSession) -> int:
    """Cursor-incremental sync of every linked Plaid item. Returns the number of items synced."""
    items = (await session.scalars(select(PlaidItem))).all()
    if not items:
        return 0
    client = plaid_client.make_client()
    synced = 0
    for item in items:
        try:
            await plaid_sync.sync_item(session, item, client)
            synced += 1
        except Exception:
            log.exception("Scheduled Plaid sync failed for item %s", item.id)
    return synced


async def sync_all_splitwise(session: AsyncSession) -> int:
    """Incremental sync of every stored Splitwise token (groups + users + expenses), advancing each token's
    cursor. Returns the number of tokens synced."""
    tokens = (await session.scalars(select(SplitwiseToken))).all()
    synced = 0
    for token in tokens:
        try:
            client = sw_client.make_client(token.access_token)
            updated_after = token.expenses_synced_at.isoformat() if token.expenses_synced_at else None
            started = datetime.now(timezone.utc)
            await importer.sync_groups(session, client, settings.splitwise_user_map)
            await importer.sync_users(session, client, settings.splitwise_user_map)
            await importer.sync_expenses(
                session, client, settings.splitwise_user_map, updated_after=updated_after, dry_run=False
            )
            token.expenses_synced_at = started
            await session.commit()
            synced += 1
        except Exception:
            await session.rollback()
            log.exception("Scheduled Splitwise sync failed for token %s", token.user_identifier)
    return synced


async def sync_all(session: AsyncSession) -> dict:
    plaid_items = await sync_all_plaid(session)
    splitwise_tokens = await sync_all_splitwise(session)
    return {"plaid_items": plaid_items, "splitwise_tokens": splitwise_tokens}
