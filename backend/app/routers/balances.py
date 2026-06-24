from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.auth import require_auth
from app.auth.scope import assert_group_member
from app.db import get_session
from app.models import Expense, Group, GroupMember, Split, User
from app.schemas.balance import BalanceEntry, FriendBalance
from app.services import friend_balances

router = APIRouter(tags=["balances"])


async def _compute(
    session: AsyncSession, group_id: UUID | None, caller: str | None = None
) -> list[BalanceEntry]:
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
        # Overall: exclude archived groups, and (when scoped) only the caller's groups.
        stmt = stmt.join(Group, Expense.group_id == Group.id).where(Group.archived_at.is_(None))
        if caller is not None:
            stmt = stmt.where(
                Expense.group_id.in_(
                    select(GroupMember.group_id).where(GroupMember.user_identifier == caller)
                )
            )

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
async def overall_balances(
    caller: str | None = Depends(require_auth), session: AsyncSession = Depends(get_session)
) -> list[BalanceEntry]:
    return await _compute(session, None, caller)


@router.get("/friends", response_model=list[FriendBalance])
async def friends(
    caller: str | None = Depends(require_auth), session: AsyncSession = Depends(get_session)
) -> list[FriendBalance]:
    """The caller's Splitwise-style pairwise balance with each person, across all their (non-archived)
    groups. Computed server-side from every expense's splits (the on-device cache is incomplete for large
    groups). Positive net = that person owes the caller."""
    if caller is None:
        return []  # no "me" to compute pairwise against (open mode)
    expenses = (
        await session.scalars(
            select(Expense)
            .where(Expense.archived_at.is_(None))
            .where(
                Expense.group_id.in_(
                    select(GroupMember.group_id).where(GroupMember.user_identifier == caller)
                )
            )
            .options(selectinload(Expense.splits))
        )
    ).all()
    nets = friend_balances.compute(caller, expenses)
    if not nets:
        return []
    users = await session.scalars(select(User).where(User.identifier.in_(list(nets))))
    names = {u.identifier: u.display_name for u in users}
    return [
        FriendBalance(identifier=identifier, display_name=names.get(identifier), net=net)
        for identifier, net in sorted(nets.items(), key=lambda kv: (names.get(kv[0]) or kv[0]).lower())
    ]


@router.get("/groups/{group_id}/balances", response_model=list[BalanceEntry])
async def group_balances(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[BalanceEntry]:
    if await session.get(Group, group_id) is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    return await _compute(session, group_id)
