"""Orchestrates a Splitwise pull into SplitBack rows, idempotently.

Splitwise's sync client calls are run via asyncio.to_thread so they fit the
async DB session.
"""
import asyncio
from uuid import UUID

from sqlalchemy import delete, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import mapper
from app.models import BackendType, Expense, Group, GroupMember, Split, User
from app.models.enums import UserSource


async def _upsert_group(session: AsyncSession, splitwise_id: str, name: str) -> UUID:
    stmt = (
        pg_insert(Group)
        .values(name=name, backend_type=BackendType.splitwise, splitwise_group_id=splitwise_id)
        .on_conflict_do_update(
            index_elements=[Group.splitwise_group_id],
            index_where=text("splitwise_group_id IS NOT NULL"),
            set_={"name": name},
        )
        .returning(Group.id)
    )
    return (await session.execute(stmt)).scalar_one()


async def _upsert_user(
    session: AsyncSession, identifier: str, display_name: str, splitwise_user_id: str
) -> None:
    # Set splitwise_user_id on conflict but never downgrade an existing (e.g. app) user.
    stmt = (
        pg_insert(User)
        .values(
            identifier=identifier,
            display_name=display_name or identifier,
            source=UserSource.splitwise,
            splitwise_user_id=splitwise_user_id,
        )
        .on_conflict_do_update(
            index_elements=[User.identifier],
            set_={"splitwise_user_id": splitwise_user_id},
        )
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


async def run_import(
    session: AsyncSession,
    access_token: str,
    dated_after: str | None,
    dated_before: str | None,
    user_map: dict[str, str],
    dry_run: bool = False,
) -> dict:
    client = sw_client.make_client(access_token)
    groups = await asyncio.to_thread(sw_client.fetch_groups, client)
    expenses = await asyncio.to_thread(
        sw_client.fetch_expenses, client, dated_after, dated_before
    )

    importable = [e for e in expenses if mapper.is_importable(e)]
    group_rows = mapper.build_group_rows(groups, expenses)
    stats = {
        "groups": len(group_rows),
        "expenses_fetched": len(expenses),
        "imported": len(importable),
        "skipped_deleted": len(expenses) - len(importable),
        "settle_ups": sum(1 for e in importable if e.get("payment")),
        "dry_run": dry_run,
    }
    if dry_run:
        return stats

    group_id_map: dict[str, UUID] = {}
    for splitwise_id, name in group_rows.items():
        group_id_map[splitwise_id] = await _upsert_group(session, splitwise_id, name)

    # Splitwise members -> users directory + group memberships
    seen_users: set[str] = set()
    for group in groups:
        our_group_id = group_id_map.get(group["splitwise_id"])
        for member in group.get("members", []):
            identifier = mapper.resolve_user_identifier(
                member["user_id"], member["first_name"], user_map
            )
            await _upsert_user(session, identifier, member["first_name"], member["user_id"])
            seen_users.add(identifier)
            if our_group_id is not None:
                await _upsert_group_member(session, our_group_id, identifier)

    for expense in importable:
        # Capture participants who may not appear in a group's member list.
        for participant in expense.get("users", []):
            identifier = mapper.resolve_user_identifier(
                participant["user_id"], participant.get("first_name", ""), user_map
            )
            await _upsert_user(
                session, identifier, participant.get("first_name", ""), participant["user_id"]
            )
            seen_users.add(identifier)
        mapped = mapper.map_expense(expense, user_map)
        await _upsert_expense(session, mapped, group_id_map[mapped["group_key"]])

    await session.commit()
    stats["users"] = len(seen_users)
    return stats
