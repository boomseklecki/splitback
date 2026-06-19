from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import settings
from app.db import get_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import importer
from app.models import BackendType, Expense, ExpenseItem, Group, GroupMember, Split, SplitwiseToken
from app.schemas.group import GroupResponse
from app.schemas.splitwise import (
    LocalImportRequest,
    LocalImportResult,
    SplitwiseImportRequest,
    SplitwiseImportResult,
    SplitwiseStatus,
    SyncRequest,
    SyncResult,
)

router = APIRouter(prefix="/splitwise", tags=["splitwise"])


@router.get("/status", response_model=SplitwiseStatus)
async def status(session: AsyncSession = Depends(get_session)) -> SplitwiseStatus:
    users = (await session.scalars(select(SplitwiseToken.user_identifier))).all()
    return SplitwiseStatus(connected=len(users) > 0, users=list(users))


async def _select_token(session: AsyncSession, as_user: str | None) -> SplitwiseToken:
    query = select(SplitwiseToken)
    if as_user:
        query = query.where(SplitwiseToken.user_identifier == as_user)
    tokens = (await session.scalars(query)).all()
    if not tokens:
        raise HTTPException(
            status_code=400, detail="No Splitwise token; authorize via /auth/splitwise/login first"
        )
    if len(tokens) > 1 and not as_user:
        raise HTTPException(status_code=400, detail="Multiple tokens stored; specify as_user")
    return tokens[0]


@router.post("/import", response_model=SplitwiseImportResult)
async def run_import(
    body: SplitwiseImportRequest, session: AsyncSession = Depends(get_session)
) -> dict:
    """Cold backfill (full window). Stamps the incremental cursor so /sync/expenses takes over."""
    token = await _select_token(session, body.as_user)
    started = datetime.now(timezone.utc)
    result = await importer.run_import(
        session,
        access_token=token.access_token,
        dated_after=body.since,
        dated_before=body.until,
        user_map=settings.splitwise_user_map,
        dry_run=body.dry_run,
    )
    if not body.dry_run:
        token.expenses_synced_at = started
        await session.commit()
    return result


@router.post("/sync/groups", response_model=SyncResult)
async def sync_groups(
    body: SyncRequest, session: AsyncSession = Depends(get_session)
) -> SyncResult:
    """Pull-to-refresh the Groups list: refresh group metadata + members."""
    token = await _select_token(session, body.as_user)
    client = sw_client.make_client(token.access_token)
    stats = await importer.sync_groups(session, client, settings.splitwise_user_map)
    return SyncResult(**stats)


@router.post("/sync/users", response_model=SyncResult)
async def sync_users(
    body: SyncRequest, session: AsyncSession = Depends(get_session)
) -> SyncResult:
    """Pull-to-refresh the People list: refresh the users directory (members + current user)."""
    token = await _select_token(session, body.as_user)
    client = sw_client.make_client(token.access_token)
    stats = await importer.sync_users(session, client, settings.splitwise_user_map)
    return SyncResult(**stats)


@router.post("/sync/expenses", response_model=SyncResult)
async def sync_expenses(
    body: SyncRequest, session: AsyncSession = Depends(get_session)
) -> SyncResult:
    """Pull-to-refresh expenses: incremental pull since the stored cursor (or `since` override).
    Catches edits/settle-ups and archives expenses Splitwise has deleted."""
    token = await _select_token(session, body.as_user)
    client = sw_client.make_client(token.access_token)
    updated_after = body.since or (
        token.expenses_synced_at.isoformat() if token.expenses_synced_at else None
    )
    started = datetime.now(timezone.utc)
    stats = await importer.sync_expenses(
        session, client, settings.splitwise_user_map,
        updated_after=updated_after, dry_run=body.dry_run,
    )
    if not body.dry_run:
        token.expenses_synced_at = started
        await session.commit()
    return SyncResult(**stats, dry_run=body.dry_run, cursor=None if body.dry_run else started)


@router.post("/groups/{group_id}/import-local", response_model=LocalImportResult)
async def import_group_local(
    group_id: UUID, body: LocalImportRequest, session: AsyncSession = Depends(get_session)
) -> LocalImportResult:
    """Clone a Splitwise-linked group into a new self-hosted group (native, full-featured
    copies), then archive the source so balances don't double-count. Archived source
    expenses are not copied; receipts/line items copy if present."""
    source = await session.get(Group, group_id)
    if source is None:
        raise HTTPException(status_code=404, detail="Group not found")
    if source.backend_type != BackendType.splitwise:
        raise HTTPException(status_code=400, detail="Source must be a Splitwise-linked group")

    expenses = (
        await session.scalars(
            select(Expense)
            .where(Expense.group_id == source.id, Expense.archived_at.is_(None))
            .options(selectinload(Expense.splits), selectinload(Expense.items))
        )
    ).all()
    members = (
        await session.scalars(select(GroupMember).where(GroupMember.group_id == source.id))
    ).all()

    new_group = Group(name=body.name or source.name, backend_type=BackendType.self_hosted)
    session.add(new_group)
    await session.flush()

    for expense in expenses:
        clone = Expense(
            group_id=new_group.id,
            description=expense.description,
            amount=expense.amount,
            currency=expense.currency,
            date=expense.date,
            category=expense.category,
        )
        clone.splits = [
            Split(user_identifier=s.user_identifier, paid_share=s.paid_share, owed_share=s.owed_share)
            for s in expense.splits
        ]
        clone.items = [
            ExpenseItem(name=i.name, quantity=i.quantity, price=i.price, category=i.category)
            for i in expense.items
        ]
        session.add(clone)

    for member in members:
        session.add(GroupMember(group_id=new_group.id, user_identifier=member.user_identifier))

    source.archived_at = datetime.now(timezone.utc)
    await session.commit()
    await session.refresh(new_group)
    return LocalImportResult(
        group=GroupResponse.model_validate(new_group), expenses_copied=len(expenses)
    )
