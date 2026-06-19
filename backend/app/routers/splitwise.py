from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import settings
from app.db import get_session
from app.integrations.splitwise import importer
from app.models import BackendType, Expense, ExpenseItem, Group, GroupMember, Split, SplitwiseToken
from app.schemas.group import GroupResponse
from app.schemas.splitwise import (
    LocalImportRequest,
    LocalImportResult,
    SplitwiseImportRequest,
    SplitwiseImportResult,
    SplitwiseStatus,
)

router = APIRouter(prefix="/splitwise", tags=["splitwise"])


@router.get("/status", response_model=SplitwiseStatus)
async def status(session: AsyncSession = Depends(get_session)) -> SplitwiseStatus:
    users = (await session.scalars(select(SplitwiseToken.user_identifier))).all()
    return SplitwiseStatus(connected=len(users) > 0, users=list(users))


@router.post("/import", response_model=SplitwiseImportResult)
async def run_import(
    body: SplitwiseImportRequest, session: AsyncSession = Depends(get_session)
) -> dict:
    query = select(SplitwiseToken)
    if body.as_user:
        query = query.where(SplitwiseToken.user_identifier == body.as_user)
    tokens = (await session.scalars(query)).all()

    if not tokens:
        raise HTTPException(
            status_code=400, detail="No Splitwise token; authorize via /auth/splitwise/login first"
        )
    if len(tokens) > 1 and not body.as_user:
        raise HTTPException(status_code=400, detail="Multiple tokens stored; specify as_user")

    return await importer.run_import(
        session,
        access_token=tokens[0].access_token,
        dated_after=body.since,
        dated_before=body.until,
        user_map=settings.splitwise_user_map,
        dry_run=body.dry_run,
    )


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
