from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models import Expense, Group, Split, User
from app.schemas.balance import BalanceEntry

router = APIRouter(tags=["balances"])


async def _compute(session: AsyncSession, group_id: UUID | None) -> list[BalanceEntry]:
    paid = func.coalesce(func.sum(Split.paid_share), 0).label("paid")
    owed = func.coalesce(func.sum(Split.owed_share), 0).label("owed")
    stmt = (
        select(Split.user_identifier, paid, owed)
        .join(Expense, Split.expense_id == Expense.id)
        .where(Expense.archived_at.is_(None))  # exclude archived expenses
        .group_by(Split.user_identifier)
    )
    if group_id is not None:
        stmt = stmt.where(Expense.group_id == group_id)
    else:
        # Overall: exclude archived groups.
        stmt = stmt.join(Group, Expense.group_id == Group.id).where(Group.archived_at.is_(None))

    rows = (await session.execute(stmt)).all()
    identifiers = [r.user_identifier for r in rows]
    names: dict[str, str] = {}
    if identifiers:
        users = await session.scalars(select(User).where(User.identifier.in_(identifiers)))
        names = {u.identifier: u.display_name for u in users}

    return [
        BalanceEntry(
            identifier=r.user_identifier,
            display_name=names.get(r.user_identifier),
            paid_total=r.paid,
            owed_total=r.owed,
            net=r.paid - r.owed,
        )
        for r in rows
    ]


@router.get("/balances", response_model=list[BalanceEntry])
async def overall_balances(session: AsyncSession = Depends(get_session)) -> list[BalanceEntry]:
    return await _compute(session, None)


@router.get("/groups/{group_id}/balances", response_model=list[BalanceEntry])
async def group_balances(
    group_id: UUID, session: AsyncSession = Depends(get_session)
) -> list[BalanceEntry]:
    if await session.get(Group, group_id) is None:
        raise HTTPException(status_code=404, detail="Group not found")
    return await _compute(session, group_id)
