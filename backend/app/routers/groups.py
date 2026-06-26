import asyncio
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.auth.scope import assert_group_member
from app.db import get_session
from app.integrations.storage import minio_client
from app.models import BackendType, Expense, Group, GroupMember, GroupOverride, Receipt
from app.schemas.group import GroupCreate, GroupResponse, GroupUpdate
from app.schemas.group_member import GroupMemberCreate, GroupMemberResponse
from app.utils import ensure_utc

router = APIRouter(prefix="/groups", tags=["groups"])


@router.post("", response_model=GroupResponse, status_code=201)
async def create_group(
    body: GroupCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Group:
    group = Group(name=body.name, backend_type=BackendType.self_hosted)
    session.add(group)
    await session.flush()
    if caller is not None:  # the creator joins, so per-caller scoping shows them their own group
        session.add(GroupMember(group_id=group.id, user_identifier=caller))
    await session.commit()
    await session.refresh(group)
    await _attach_group_overrides(session, caller, [group])
    return group


# Override columns persisted per (owner, group). `hidden` defaults to False; include flags default null.
_GROUP_OVERRIDE_FIELDS = ("hidden", "include_in_spending", "include_in_cash_flow")


async def _attach_group_overrides(
    session: AsyncSession, caller: str | None, groups: list[Group]
) -> None:
    """Populate each group's per-user override fields (`hidden`, `include_in_spending`,
    `include_in_cash_flow`) from the caller's `group_overrides` row (none in open mode → defaults). Sets
    transient attributes the response serializes via `from_attributes`."""
    by_id: dict = {}
    ids = [g.id for g in groups]
    if caller is not None and ids:
        rows = await session.scalars(
            select(GroupOverride).where(
                GroupOverride.owner_identifier == caller, GroupOverride.group_id.in_(ids)
            )
        )
        by_id = {o.group_id: o for o in rows}
    for g in groups:
        override = by_id.get(g.id)
        g.hidden = bool(override.hidden) if override is not None and override.hidden is not None else False
        g.include_in_spending = override.include_in_spending if override is not None else None
        g.include_in_cash_flow = override.include_in_cash_flow if override is not None else None


@router.get("", response_model=list[GroupResponse])
async def list_groups(
    backend_type: BackendType | None = None,
    include_hidden: bool = False,
    updated_since: datetime | None = None,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Group]:
    stmt = select(Group)
    if caller is not None:  # only groups the caller is a member of
        stmt = stmt.where(
            Group.id.in_(select(GroupMember.group_id).where(GroupMember.user_identifier == caller))
        )
    if backend_type is not None:
        stmt = stmt.where(Group.backend_type == backend_type)
    # Always exclude a group superseded by a local import (its expenses live on the self-hosted clone).
    stmt = stmt.where(Group.superseded_at.is_(None))
    if caller is not None and not include_hidden:  # exclude groups the caller has hidden (open mode hides none)
        stmt = stmt.where(
            Group.id.notin_(
                select(GroupOverride.group_id).where(
                    GroupOverride.owner_identifier == caller, GroupOverride.hidden.is_(True)
                )
            )
        )
    if updated_since is not None:
        stmt = stmt.where(Group.updated_at >= ensure_utc(updated_since))
    rows = list(await session.scalars(stmt.order_by(Group.created_at)))
    await _attach_group_overrides(session, caller, rows)
    return rows


@router.get("/{group_id}", response_model=GroupResponse)
async def get_group(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Group:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    await _attach_group_overrides(session, caller, [group])
    return group


@router.patch("/{group_id}", response_model=GroupResponse)
async def update_group(
    group_id: UUID,
    body: GroupUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Group:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    if body.name is not None:  # name is shared/sourced — stays on the group row
        group.name = body.name
    if caller is not None:  # the rest are the caller's per-user overrides
        fields = body.model_dump(exclude_unset=True)
        fields.pop("name", None)
        if fields.get("hidden") is False:  # hidden False = the default (shown) → clear
            fields["hidden"] = None
        if fields:
            override = await session.scalar(
                select(GroupOverride).where(
                    GroupOverride.owner_identifier == caller, GroupOverride.group_id == group_id
                )
            )
            if override is None:
                override = GroupOverride(owner_identifier=caller, group_id=group_id)
                session.add(override)
            for field, value in fields.items():
                setattr(override, field, value)
            if all(getattr(override, field) is None for field in _GROUP_OVERRIDE_FIELDS):
                await session.delete(override)
    await session.commit()
    await session.refresh(group)
    await _attach_group_overrides(session, caller, [group])
    return group


async def _hard_delete_group(session: AsyncSession, group: Group) -> None:
    keys = await session.scalars(
        select(Receipt.object_key)
        .join(Expense, Receipt.expense_id == Expense.id)
        .where(Expense.group_id == group.id)
    )
    for key in keys:
        try:
            await asyncio.to_thread(minio_client.remove, key)
        except Exception:
            pass  # best-effort; don't block the delete on storage hiccups
    await session.delete(group)
    await session.commit()


@router.delete("/{group_id}", status_code=204)
async def delete_group(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    if group.backend_type != BackendType.self_hosted:
        raise HTTPException(
            status_code=409, detail="Only self-hosted groups can be deleted"
        )
    await _hard_delete_group(session, group)


@router.get("/{group_id}/members", response_model=list[GroupMemberResponse])
async def list_members(
    group_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[GroupMember]:
    await assert_group_member(session, group_id, caller)
    rows = await session.scalars(
        select(GroupMember)
        .where(GroupMember.group_id == group_id)
        .order_by(GroupMember.user_identifier)
    )
    return list(rows)


@router.post("/{group_id}/members", response_model=GroupMemberResponse, status_code=201)
async def add_member(
    group_id: UUID,
    body: GroupMemberCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> GroupMember:
    if await session.get(Group, group_id) is None:
        raise HTTPException(status_code=404, detail="Group not found")
    await assert_group_member(session, group_id, caller)
    existing = await session.scalar(
        select(GroupMember).where(
            GroupMember.group_id == group_id,
            GroupMember.user_identifier == body.user_identifier,
        )
    )
    if existing is not None:
        return existing
    member = GroupMember(group_id=group_id, user_identifier=body.user_identifier)
    session.add(member)
    await session.commit()
    await session.refresh(member)
    return member


@router.delete("/{group_id}/members/{user_identifier}", status_code=204)
async def remove_member(
    group_id: UUID,
    user_identifier: str,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    await assert_group_member(session, group_id, caller)
    member = await session.scalar(
        select(GroupMember).where(
            GroupMember.group_id == group_id,
            GroupMember.user_identifier == user_identifier,
        )
    )
    if member is None:
        raise HTTPException(status_code=404, detail="Member not found")
    await session.delete(member)
    await session.commit()
