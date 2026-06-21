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
from app.models import BackendType, Expense, Group, GroupMember, Receipt
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
    return group


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
    if not include_hidden:
        stmt = stmt.where(Group.hidden.is_(False))
    if updated_since is not None:
        stmt = stmt.where(Group.updated_at >= ensure_utc(updated_since))
    rows = await session.scalars(stmt.order_by(Group.created_at))
    return list(rows)


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
    if body.name is not None:
        group.name = body.name
    if body.hidden is not None:
        group.hidden = body.hidden
    await session.commit()
    await session.refresh(group)
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
