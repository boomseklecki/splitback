"""Idempotency checks against the running Postgres — no Splitwise needed.

Drives the importer's upsert helpers with a fabricated mapped batch and asserts
re-running produces no duplicates. Cleans up its own rows.
"""
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.db import async_session
from app.integrations.splitwise import importer
from app.models import Expense, Group, Split

GROUP_KEY = "test-grp-zzz"
EXPENSE_KEY = "test-exp-zzz"


async def _cleanup(session) -> None:
    await session.execute(delete(Expense).where(Expense.splitwise_expense_id == EXPENSE_KEY))
    await session.execute(delete(Group).where(Group.splitwise_group_id == GROUP_KEY))
    await session.commit()


async def test_group_upsert_idempotent():
    async with async_session() as session:
        try:
            id1 = await importer._upsert_group(session, GROUP_KEY, "Original")
            id2 = await importer._upsert_group(session, GROUP_KEY, "Renamed")
            await session.commit()
            assert id1 == id2
            count = await session.scalar(
                select(func.count()).select_from(Group).where(
                    Group.splitwise_group_id == GROUP_KEY
                )
            )
            assert count == 1
            name = await session.scalar(
                select(Group.name).where(Group.splitwise_group_id == GROUP_KEY)
            )
            assert name == "Renamed"
        finally:
            await _cleanup(session)


async def test_expense_upsert_replaces_splits():
    async with async_session() as session:
        try:
            group_id = await importer._upsert_group(session, GROUP_KEY, "G")
            mapped = {
                "splitwise_expense_id": EXPENSE_KEY,
                "group_key": GROUP_KEY,
                "description": "first",
                "amount": Decimal("10.00"),
                "currency": "USD",
                "date": date(2023, 1, 1),
                "category": "X",
                "splits": [
                    {"user_identifier": "matt", "paid_share": Decimal("10"), "owed_share": Decimal("5")},
                    {"user_identifier": "nikki", "paid_share": Decimal("0"), "owed_share": Decimal("5")},
                ],
            }
            await importer._upsert_expense(session, mapped, group_id)
            await session.commit()

            # Re-import with an updated description and a single split.
            mapped["description"] = "second"
            mapped["splits"] = [
                {"user_identifier": "matt", "paid_share": Decimal("10"), "owed_share": Decimal("10")},
            ]
            await importer._upsert_expense(session, mapped, group_id)
            await session.commit()

            exp_count = await session.scalar(
                select(func.count()).select_from(Expense).where(
                    Expense.splitwise_expense_id == EXPENSE_KEY
                )
            )
            assert exp_count == 1
            expense_id = await session.scalar(
                select(Expense.id).where(Expense.splitwise_expense_id == EXPENSE_KEY)
            )
            split_count = await session.scalar(
                select(func.count()).select_from(Split).where(Split.expense_id == expense_id)
            )
            assert split_count == 1
            description = await session.scalar(
                select(Expense.description).where(Expense.id == expense_id)
            )
            assert description == "second"
        finally:
            await _cleanup(session)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
