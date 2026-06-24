import asyncio
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.auth.scope import assert_group_member
from app.config import settings
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


async def _attach_group_overrides(
    session: AsyncSession, caller: str | None, groups: list[Group]
) -> None:
    """Populate each group's per-user `hidden` flag from the caller's `group_overrides` row (none in open
    mode → default False). The column moved to `group_overrides`; this sets a transient attribute the response
    serializes via `from_attributes`."""
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


@router.get("", response_model=list[GroupResponse])
async def list_groups(
    backend_type: BackendType | None = None,
    include_archived: bool = False,
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
    if not include_archived:
        stmt = stmt.where(Group.archived_at.is_(None))
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
    if body.hidden is not None and caller is not None:  # `hidden` is the caller's per-user override
        override = await session.scalar(
            select(GroupOverride).where(
                GroupOverride.owner_identifier == caller, GroupOverride.group_id == group_id
            )
        )
        if body.hidden:  # set the caller's override
            if override is None:
                session.add(GroupOverride(owner_identifier=caller, group_id=group_id, hidden=True))
            else:
                override.hidden = True
        elif override is not None:  # hidden=False is the default → drop the row
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
            status_code=409, detail="Only self-hosted groups can be archived or deleted"
        )
    if settings.groups_hard_delete_enabled:
        await _hard_delete_group(session, group)
    else:
        group.archived_at = datetime.now(timezone.utc)
        await session.commit()


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
