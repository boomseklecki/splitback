"""Per-caller authorization helpers. Every check is a **no-op when `caller is None`** (open mode / no auth),
so open deployments and the dev/test stacks keep seeing everything; scoping only bites once a caller is
authenticated. Lists filter by the caller; single-row access asserts ownership/membership → 403."""
from uuid import UUID

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import GroupMember


def _forbid() -> None:
    raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not permitted for this account.")


def assert_owner(owner_identifier: str | None, caller: str | None) -> None:
    """For owned resources (accounts/transactions/goals/plaid items)."""
    if caller is not None and owner_identifier != caller:
        _forbid()


async def caller_group_ids(session: AsyncSession, caller: str) -> list[UUID]:
    """The group ids the caller is a member of (for scoping group/expense lists)."""
    rows = await session.scalars(
        select(GroupMember.group_id).where(GroupMember.user_identifier == caller)
    )
    return list(rows)


async def caller_co_members(session: AsyncSession, caller: str) -> set[str]:
    """Identifiers that share at least one group with the caller (includes the caller). Used to scope the
    people directory's contact details to people you actually share expenses with."""
    rows = await session.scalars(
        select(GroupMember.user_identifier).where(
            GroupMember.group_id.in_(
                select(GroupMember.group_id).where(GroupMember.user_identifier == caller)
            )
        )
    )
    return set(rows)


async def is_group_member(session: AsyncSession, group_id: UUID, caller: str) -> bool:
    found = await session.scalar(
        select(GroupMember.id).where(
            GroupMember.group_id == group_id, GroupMember.user_identifier == caller
        )
    )
    return found is not None


async def assert_group_member(session: AsyncSession, group_id: UUID, caller: str | None) -> None:
    """For group-scoped resources (groups/expenses/receipts/group balances)."""
    if caller is None:
        return
    if not await is_group_member(session, group_id, caller):
        _forbid()
