"""Orchestrates a Splitwise pull into SplitBack rows, idempotently.

Splitwise's sync client calls are run via asyncio.to_thread so they fit the
async DB session.
"""
import asyncio
import logging
from uuid import UUID

from sqlalchemy import case, delete, func, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import mapper
from app.integrations.storage import minio_client
from app.models import (
    BackendType,
    Expense,
    Friend,
    Group,
    GroupMember,
    Notification,
    Split,
    User,
)
from app.models.enums import NotificationSource, UserSource

log = logging.getLogger(__name__)


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
                # A group present in getGroups() is active on Splitwise → clear any stale "deleted" flag
                # (e.g. restored elsewhere).
                "deleted_at": None,
                # on_conflict bypasses SQLAlchemy onupdate; bump so updated_at tracks the last sync (the
                # freshness signal the app's smart-refresh thresholds read).
                "updated_at": func.now(),
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


async def _resolve_identifier(
    session: AsyncSession,
    *,
    splitwise_user_id: str,
    first_name: str,
    email: str | None,
    user_map: dict[str, str],
) -> str:
    """The local identifier a Splitwise user maps to, **reusing an existing user** so the import and
    sign-in (`auth.identity.resolve_user`) converge on one identity instead of minting a duplicate:
      1. a user already linked to this `splitwise_user_id`,
      2. else a user with the same `email` (e.g. an Apple/Google sign-in) — keyed by email, the same
         signal sign-in links on,
      3. else the deterministic mapper fallback (operator `user_map` → slugified first name).
    Keeping the readable string identifier; this only changes *which* existing one we resolve to."""
    linked = await session.scalar(
        select(User.identifier).where(User.splitwise_user_id == splitwise_user_id)
    )
    if linked:
        return linked
    if email:
        by_email = await session.scalar(
            select(User.identifier).where(User.email == email)
            .order_by(User.created_at).limit(1)
        )
        if by_email:
            return by_email
    return mapper.resolve_user_identifier(splitwise_user_id, first_name, user_map)


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
            # on_conflict bypasses onupdate; bump so updated_at tracks the last sync (see _upsert_account).
            "updated_at": func.now(),
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
            # on_conflict bypasses onupdate; bump so updated_at tracks the last sync (see _upsert_account).
            set_={**fields, "updated_at": func.now()},
        )
        .returning(Expense.id)
    )
    expense_id = (await session.execute(stmt)).scalar_one()

    # Splits have no natural key, so replace them wholesale on each import.
    await session.execute(delete(Split).where(Split.expense_id == expense_id))
    for split in mapped["splits"]:
        await session.execute(pg_insert(Split).values(expense_id=expense_id, **split))


async def _delete_by_swid(session: AsyncSession, splitwise_expense_id: str) -> int:
    """Hard-delete a locally-stored expense that Splitwise has deleted (cascades splits/items/receipt rows;
    best-effort MinIO cleanup for any uploaded receipts). Returns rows affected (0/1)."""
    expense = await session.scalar(
        select(Expense)
        .where(Expense.splitwise_expense_id == splitwise_expense_id)
        .options(selectinload(Expense.receipts))
    )
    if expense is None:
        return 0
    for receipt in expense.receipts:
        try:
            await asyncio.to_thread(minio_client.remove, receipt.object_key)
        except Exception:
            pass  # best-effort storage cleanup
    await session.delete(expense)
    return 1


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
            identifier = await _resolve_identifier(
                session, splitwise_user_id=member["user_id"], first_name=member["first_name"],
                email=member.get("email"), user_map=user_map,
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
            identifier = await _resolve_identifier(
                session, splitwise_user_id=member["user_id"], first_name=member["first_name"],
                email=member.get("email"), user_map=user_map,
            )
            await _upsert_user(
                session, identifier, _full_name(member), member["user_id"],
                email=member.get("email"), avatar_url=member.get("picture"),
                avatar_authoritative=True,
                registration_status=member.get("registration_status"),
            )
            seen_users.add(identifier)
    current = await asyncio.to_thread(sw_client.get_current_user, client)
    identifier = await _resolve_identifier(
        session, splitwise_user_id=current["splitwise_id"], first_name=current["first_name"],
        email=current.get("email"), user_map=user_map,
    )
    await _upsert_user(
        session, identifier, _full_name(current), current["splitwise_id"],
        email=current.get("email"), avatar_url=current.get("picture"),
        avatar_authoritative=True, registration_status="confirmed",
    )
    seen_users.add(identifier)
    await session.commit()
    return {"users": len(seen_users)}


async def _persist_expense(
    session: AsyncSession,
    expense: dict,
    user_map: dict[str, str],
    *,
    group_cache: dict[str, UUID],
    resolved: dict[str, str],
    seen_users: set[str],
) -> None:
    """Resolve one importable expense's participants/creator/editor into the directory, then upsert
    the expense + its splits. Shared by the windowed `sync_expenses` and the single `sync_one_expense`."""
    for participant in expense.get("users", []):
        identifier = await _resolve_identifier(
            session, splitwise_user_id=participant["user_id"],
            first_name=participant.get("first_name", ""),
            email=participant.get("email"), user_map=user_map,
        )
        resolved[participant["user_id"]] = identifier
        await _upsert_user(
            session, identifier, _full_name(participant), participant["user_id"],
            email=participant.get("email"), avatar_url=participant.get("picture"),
            registration_status=participant.get("registration_status"),
        )
        seen_users.add(identifier)
    # Ensure the creator/editor are in the directory so "Added by"/"Edited by" resolve to names.
    for ref in (expense.get("created_by"), expense.get("updated_by")):
        if ref:
            identifier = await _resolve_identifier(
                session, splitwise_user_id=ref["user_id"], first_name=ref.get("first_name", ""),
                email=ref.get("email"), user_map=user_map,
            )
            resolved[ref["user_id"]] = identifier
            await _upsert_user(session, identifier, _full_name(ref), ref["user_id"])
            seen_users.add(identifier)
    mapped = mapper.map_expense(expense, {**user_map, **resolved})
    group_id = await _ensure_group(session, mapped["group_key"], group_cache)
    await _upsert_expense(session, mapped, group_id)


async def sync_expenses(
    session: AsyncSession,
    client,
    user_map: dict[str, str],
    *,
    updated_after: str | None = None,
    updated_before: str | None = None,
    dated_after: str | None = None,
    dated_before: str | None = None,
    group_id: str | None = None,
    friend_id: str | None = None,
    dry_run: bool = False,
) -> dict:
    """Upsert expenses in a window. `updated_after` = incremental (deltas + deletions); `dated_*` =
    backfill by date. `group_id`/`friend_id` scope the pull to one group/friend (drill-in). Expenses
    Splitwise has deleted are hard-deleted locally. Commits."""
    expenses = await asyncio.to_thread(
        sw_client.fetch_expenses, client,
        dated_after=dated_after, dated_before=dated_before,
        updated_after=updated_after, updated_before=updated_before,
        group_id=group_id, friend_id=friend_id,
    )
    importable = [e for e in expenses if mapper.is_importable(e)]
    deleted = [e for e in expenses if not mapper.is_importable(e)]
    stats = {
        "expenses_fetched": len(expenses),
        "imported": len(importable),
        "skipped_deleted": len(deleted),
        "settle_ups": sum(1 for e in importable if e.get("payment")),
        "deleted": 0,
    }
    if dry_run:
        return stats

    deleted_count = 0
    for expense in deleted:
        deleted_count += await _delete_by_swid(session, expense["splitwise_id"])

    seen_users: set[str] = set()
    group_cache: dict[str, UUID] = {}
    # Splitwise user_id -> resolved local identifier, threaded into map_expense so the splits
    # (created_by / updated_by / each share) carry the SAME identifier we upsert, including any
    # existing user matched by splitwise_user_id/email.
    resolved: dict[str, str] = {}
    imported = 0
    failed = 0
    for expense in importable:
        # Per-expense savepoint: one bad expense (mapping/integrity error) is skipped, not a whole-window
        # rollback that loses every expense in the import.
        try:
            async with session.begin_nested():
                await _persist_expense(
                    session, expense, user_map,
                    group_cache=group_cache, resolved=resolved, seen_users=seen_users,
                )
            imported += 1
        except Exception:
            failed += 1
            log.warning("expense import failed (splitwise_id=%s); skipping",
                        expense.get("splitwise_id"), exc_info=True)

    await session.commit()
    stats["imported"] = imported  # actual successes (the pre-loop value was the projected count)
    stats["failed"] = failed
    stats["deleted"] = deleted_count
    stats["users"] = len(seen_users)
    return stats


async def sync_one_expense(
    session: AsyncSession, client, user_map: dict[str, str], splitwise_expense_id: str
) -> dict:
    """Refresh a single expense by id (drill-in scoped sync): upsert it, or hard-delete it locally when
    Splitwise has deleted it. Does NOT advance the token cursor. Commits."""
    expense = await asyncio.to_thread(sw_client.fetch_expense, client, splitwise_expense_id)
    stats = {"expenses_fetched": 0, "imported": 0, "deleted": 0, "settle_ups": 0, "users": 0}
    if expense is None:
        await session.commit()
        return stats
    stats["expenses_fetched"] = 1
    if not mapper.is_importable(expense):
        stats["deleted"] = await _delete_by_swid(session, expense["splitwise_id"])
        await session.commit()
        return stats
    seen_users: set[str] = set()
    await _persist_expense(
        session, expense, user_map, group_cache={}, resolved={}, seen_users=seen_users,
    )
    await session.commit()
    stats["imported"] = 1
    stats["settle_ups"] = 1 if expense.get("payment") else 0
    stats["users"] = len(seen_users)
    return stats


async def _upsert_friend(session: AsyncSession, owner_identifier: str, friend: dict, identifier: str | None) -> None:
    """Cache one Splitwise friend's identity for `owner_identifier`. Identity only — balances stay
    live via /balances/friends. on_conflict bumps updated_at (the freshness signal smart-refresh reads)."""
    values = {
        "owner_identifier": owner_identifier,
        "splitwise_friend_id": friend["splitwise_id"],
        "identifier": identifier,
        "first_name": friend.get("first_name") or None,
        "last_name": friend.get("last_name") or None,
        "email": friend.get("email"),
        "avatar_url": friend.get("picture"),
    }
    stmt = (
        pg_insert(Friend)
        .values(**values)
        .on_conflict_do_update(
            constraint="uq_friends_owner_friend",
            set_={
                "identifier": identifier,
                "first_name": values["first_name"],
                "last_name": values["last_name"],
                "email": values["email"],
                "avatar_url": values["avatar_url"],
                "updated_at": func.now(),
            },
        )
    )
    await session.execute(stmt)


async def sync_friends(
    session: AsyncSession, client, user_map: dict[str, str], owner_identifier: str
) -> dict:
    """Refresh the token owner's Splitwise friends into the friends cache (and the users directory),
    so friends with no shared group still resolve to a name/avatar. Commits."""
    friends = await asyncio.to_thread(sw_client.fetch_friends, client)
    for friend in friends:
        identifier = await _resolve_identifier(
            session, splitwise_user_id=friend["splitwise_id"],
            first_name=friend.get("first_name", ""),
            email=friend.get("email"), user_map=user_map,
        )
        await _upsert_user(
            session, identifier, _full_name(friend), friend["splitwise_id"],
            email=friend.get("email"), avatar_url=friend.get("picture"),
        )
        await _upsert_friend(session, owner_identifier, friend, identifier)
    await session.commit()
    return {"friends": len(friends)}


async def sync_notifications(
    session: AsyncSession, client, owner_identifier: str, *, retention: int, access_token: str | None = None
) -> dict:
    """Pull the owner's recent Splitwise notifications into the generic notifications table (deduped by
    splitwise_id) and prune to the newest `retention` rows for that owner. Commits."""
    notifications = await asyncio.to_thread(sw_client.fetch_notifications, client, access_token)
    for note in notifications:
        if not note.get("splitwise_id"):
            continue
        values = {
            "owner_identifier": owner_identifier,
            "source": NotificationSource.splitwise,
            "splitwise_id": note["splitwise_id"],
            "type": note.get("type"),
            "content": note.get("content") or "",
            "created_at": mapper._parse_datetime(note.get("created_at")),
        }
        stmt = (
            pg_insert(Notification)
            .values(**{k: v for k, v in values.items() if v is not None})
            .on_conflict_do_update(
                index_elements=[Notification.owner_identifier, Notification.source, Notification.splitwise_id],
                index_where=text("splitwise_id IS NOT NULL"),
                set_={"type": values["type"], "content": values["content"]},
            )
        )
        await session.execute(stmt)
    # Prune to the newest `retention` rows for this owner.
    keep = (
        select(Notification.id)
        .where(Notification.owner_identifier == owner_identifier)
        .order_by(Notification.created_at.desc())
        .limit(retention)
    )
    await session.execute(
        delete(Notification)
        .where(Notification.owner_identifier == owner_identifier)
        .where(Notification.id.not_in(keep))
    )
    await session.commit()
    return {"notifications": len(notifications)}


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
