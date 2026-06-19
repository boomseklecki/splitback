"""Orchestrates a Splitwise pull into SplitBack rows, idempotently.

Splitwise's sync client calls are run via asyncio.to_thread so they fit the
async DB session.
"""
import asyncio
from uuid import UUID

from sqlalchemy import case, delete, func, select, text, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import mapper
from app.models import BackendType, Expense, Group, GroupMember, Split, User
from app.models.enums import UserSource


async def _upsert_group(
    session: AsyncSession,
    splitwise_id: str,
    name: str,
    group_type: str | None = None,
    avatar_url: str | None = None,
    cover_photo_url: str | None = None,
) -> UUID:
    # Group metadata comes authoritatively from getGroups, so set it directly on conflict (a removed
    # or default avatar clears). Synthesized expense-only groups pass None and leave fields blank.
    values = {
        "name": name,
        "backend_type": BackendType.splitwise,
        "splitwise_group_id": splitwise_id,
        "group_type": group_type,
        "avatar_url": avatar_url,
        "cover_photo_url": cover_photo_url,
    }
    stmt = (
        pg_insert(Group)
        .values(**values)
        .on_conflict_do_update(
            index_elements=[Group.splitwise_group_id],
            index_where=text("splitwise_group_id IS NOT NULL"),
            set_={
                "name": name,
                "group_type": group_type,
                "avatar_url": avatar_url,
                "cover_photo_url": cover_photo_url,
            },
        )
        .returning(Group.id)
    )
    return (await session.execute(stmt)).scalar_one()


def _full_name(member: dict) -> str:
    """Splitwise gives first + last separately; join into a display name (e.g. 'Nikki G')."""
    first = (member.get("first_name") or "").strip()
    last = (member.get("last_name") or "").strip()
    return " ".join(part for part in (first, last) if part)


async def _upsert_user(
    session: AsyncSession,
    identifier: str,
    display_name: str,
    splitwise_user_id: str,
    email: str | None = None,
    avatar_url: str | None = None,
    avatar_authoritative: bool = False,
    registration_status: str | None = None,
) -> None:
    # On conflict, always link the splitwise_user_id, but only refresh display name + email + avatar
    # for Splitwise-sourced rows so we never clobber an app user's chosen profile (or downgrade their
    # source). Email is coalesced so a later record without one doesn't wipe a known address. Avatar is
    # set directly from an authoritative source (group members) so dropping a placeholder clears it,
    # but coalesced from secondary sources (expense participants) so they can't wipe a known avatar.
    stmt = pg_insert(User).values(
        identifier=identifier,
        display_name=display_name or identifier,
        source=UserSource.splitwise,
        splitwise_user_id=splitwise_user_id,
        email=email,
        avatar_url=avatar_url,
        registration_status=registration_status,
    )
    is_splitwise = User.source == UserSource.splitwise
    avatar_value = (
        stmt.excluded.avatar_url if avatar_authoritative
        else func.coalesce(stmt.excluded.avatar_url, User.avatar_url)
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=[User.identifier],
        set_={
            "splitwise_user_id": splitwise_user_id,
            "display_name": case((is_splitwise, stmt.excluded.display_name), else_=User.display_name),
            "email": case(
                (is_splitwise, func.coalesce(stmt.excluded.email, User.email)),
                else_=User.email,
            ),
            "avatar_url": case((is_splitwise, avatar_value), else_=User.avatar_url),
            "registration_status": case(
                (is_splitwise, func.coalesce(stmt.excluded.registration_status, User.registration_status)),
                else_=User.registration_status,
            ),
        },
    )
    await session.execute(stmt)


async def _upsert_group_member(
    session: AsyncSession, group_id: UUID, user_identifier: str
) -> None:
    stmt = (
        pg_insert(GroupMember)
        .values(group_id=group_id, user_identifier=user_identifier)
        .on_conflict_do_nothing(constraint="uq_group_members_group_user")
    )
    await session.execute(stmt)


async def _upsert_expense(session: AsyncSession, mapped: dict, group_id: UUID) -> None:
    fields = {
        "group_id": group_id,
        "description": mapped["description"],
        "amount": mapped["amount"],
        "currency": mapped["currency"],
        "date": mapped["date"],
        "category": mapped["category"],
        "created_by": mapped.get("created_by"),
        "updated_by": mapped.get("updated_by"),
        "splitwise_created_at": mapped.get("splitwise_created_at"),
        "splitwise_updated_at": mapped.get("splitwise_updated_at"),
        "notes": mapped.get("notes"),
        "comments_count": mapped.get("comments_count"),
        "repeats": mapped.get("repeats"),
        "repeat_interval": mapped.get("repeat_interval"),
        "expense_bundle_id": mapped.get("expense_bundle_id"),
        "splitwise_receipt_url": mapped.get("splitwise_receipt_url"),
        "repayments": mapped.get("repayments"),
    }
    stmt = (
        pg_insert(Expense)
        .values(splitwise_expense_id=mapped["splitwise_expense_id"], **fields)
        .on_conflict_do_update(
            index_elements=[Expense.splitwise_expense_id],
            set_=fields,
        )
        .returning(Expense.id)
    )
    expense_id = (await session.execute(stmt)).scalar_one()

    # Splits have no natural key, so replace them wholesale on each import.
    await session.execute(delete(Split).where(Split.expense_id == expense_id))
    for split in mapped["splits"]:
        await session.execute(pg_insert(Split).values(expense_id=expense_id, **split))


async def _archive_deleted(session: AsyncSession, splitwise_expense_id: str) -> int:
    """Archive a locally-stored expense that Splitwise has deleted. Returns rows affected (0/1)."""
    result = await session.execute(
        update(Expense)
        .where(
            Expense.splitwise_expense_id == splitwise_expense_id,
            Expense.archived_at.is_(None),
        )
        .values(archived_at=func.now())
    )
    return result.rowcount or 0


async def _ensure_group(session: AsyncSession, group_key: str, cache: dict[str, UUID]) -> UUID:
    """Resolve an expense's group to a local id, creating a minimal placeholder if it doesn't exist
    yet. Never overwrites the metadata of a group already synced by sync_groups."""
    if group_key in cache:
        return cache[group_key]
    existing = await session.scalar(select(Group.id).where(Group.splitwise_group_id == group_key))
    if existing is None:
        name = (
            mapper.NON_GROUP_NAME
            if group_key == mapper.NON_GROUP_SENTINEL
            else f"Splitwise group {group_key}"
        )
        existing = await _upsert_group(session, group_key, name)
    cache[group_key] = existing
    return existing


async def sync_groups(
    session: AsyncSession, client, user_map: dict[str, str], groups: list[dict] | None = None
) -> dict:
    """Refresh group metadata + members (users directory + memberships). Commits."""
    if groups is None:
        groups = await asyncio.to_thread(sw_client.fetch_groups, client)
    seen_users: set[str] = set()
    for group in groups:
        group_id = await _upsert_group(
            session, group["splitwise_id"], group["name"],
            group_type=group.get("group_type"),
            avatar_url=group.get("avatar_url"),
            cover_photo_url=group.get("cover_photo_url"),
        )
        for member in group.get("members", []):
            identifier = mapper.resolve_user_identifier(
                member["user_id"], member["first_name"], user_map
            )
            await _upsert_user(
                session, identifier, _full_name(member), member["user_id"],
                email=member.get("email"), avatar_url=member.get("picture"),
                avatar_authoritative=True,
                registration_status=member.get("registration_status"),
            )
            seen_users.add(identifier)
            await _upsert_group_member(session, group_id, identifier)
    await session.commit()
    return {"groups": len(groups), "users": len(seen_users)}


async def sync_users(
    session: AsyncSession, client, user_map: dict[str, str], groups: list[dict] | None = None
) -> dict:
    """Refresh the users directory: every group member plus the authenticated current user. No
    group metadata writes. Commits."""
    if groups is None:
        groups = await asyncio.to_thread(sw_client.fetch_groups, client)
    seen_users: set[str] = set()
    for group in groups:
        for member in group.get("members", []):
            identifier = mapper.resolve_user_identifier(
                member["user_id"], member["first_name"], user_map
            )
            await _upsert_user(
                session, identifier, _full_name(member), member["user_id"],
                email=member.get("email"), avatar_url=member.get("picture"),
                avatar_authoritative=True,
                registration_status=member.get("registration_status"),
            )
            seen_users.add(identifier)
    current = await asyncio.to_thread(sw_client.get_current_user, client)
    identifier = mapper.resolve_user_identifier(
        current["splitwise_id"], current["first_name"], user_map
    )
    await _upsert_user(
        session, identifier, _full_name(current), current["splitwise_id"],
        email=current.get("email"), avatar_url=current.get("picture"),
        avatar_authoritative=True, registration_status="confirmed",
    )
    seen_users.add(identifier)
    await session.commit()
    return {"users": len(seen_users)}


async def sync_expenses(
    session: AsyncSession,
    client,
    user_map: dict[str, str],
    *,
    updated_after: str | None = None,
    updated_before: str | None = None,
    dated_after: str | None = None,
    dated_before: str | None = None,
    dry_run: bool = False,
) -> dict:
    """Upsert expenses in a window. `updated_after` = incremental (deltas + deletions); `dated_*` =
    backfill by date. Expenses Splitwise has deleted are archived locally. Commits."""
    expenses = await asyncio.to_thread(
        sw_client.fetch_expenses, client,
        dated_after=dated_after, dated_before=dated_before,
        updated_after=updated_after, updated_before=updated_before,
    )
    importable = [e for e in expenses if mapper.is_importable(e)]
    deleted = [e for e in expenses if not mapper.is_importable(e)]
    stats = {
        "expenses_fetched": len(expenses),
        "imported": len(importable),
        "skipped_deleted": len(deleted),
        "settle_ups": sum(1 for e in importable if e.get("payment")),
        "archived_deleted": 0,
    }
    if dry_run:
        return stats

    archived = 0
    for expense in deleted:
        archived += await _archive_deleted(session, expense["splitwise_id"])

    seen_users: set[str] = set()
    group_cache: dict[str, UUID] = {}
    for expense in importable:
        for participant in expense.get("users", []):
            identifier = mapper.resolve_user_identifier(
                participant["user_id"], participant.get("first_name", ""), user_map
            )
            await _upsert_user(
                session, identifier, _full_name(participant), participant["user_id"],
                email=participant.get("email"), avatar_url=participant.get("picture"),
                registration_status=participant.get("registration_status"),
            )
            seen_users.add(identifier)
        # Ensure the creator/editor are in the directory so "Added by"/"Edited by" resolve to names.
        for ref in (expense.get("created_by"), expense.get("updated_by")):
            if ref:
                identifier = mapper.resolve_user_identifier(
                    ref["user_id"], ref.get("first_name", ""), user_map
                )
                await _upsert_user(session, identifier, _full_name(ref), ref["user_id"])
                seen_users.add(identifier)
        mapped = mapper.map_expense(expense, user_map)
        group_id = await _ensure_group(session, mapped["group_key"], group_cache)
        await _upsert_expense(session, mapped, group_id)

    await session.commit()
    stats["archived_deleted"] = archived
    stats["users"] = len(seen_users)
    return stats


async def run_import(
    session: AsyncSession,
    access_token: str,
    dated_after: str | None,
    dated_before: str | None,
    user_map: dict[str, str],
    dry_run: bool = False,
) -> dict:
    """Cold backfill: groups -> users -> expenses (each phase commits independently). The caller
    stamps the incremental cursor (SplitwiseToken.expenses_synced_at) after this succeeds."""
    client = sw_client.make_client(access_token)
    groups = await asyncio.to_thread(sw_client.fetch_groups, client)

    if dry_run:
        exp = await sync_expenses(
            session, client, user_map,
            dated_after=dated_after, dated_before=dated_before, dry_run=True,
        )
        return {"groups": len(groups), "dry_run": True, **exp}

    g = await sync_groups(session, client, user_map, groups=groups)
    u = await sync_users(session, client, user_map, groups=groups)
    e = await sync_expenses(
        session, client, user_map, dated_after=dated_after, dated_before=dated_before
    )
    return {"groups": g["groups"], "dry_run": False, **e, "users": u["users"]}
