"""Seed the DEVELOPMENT backend with synthetic Splitwise-style data.

Generates fake-but-realistic groups/users/expenses/splits/items (see app.integrations.dev_seed.generator)
and inserts them. With --wipe it first clears the Splitwise side so dev is reset to a clean synthetic state:
all groups (cascading expenses/splits/items), group members, every user EXCEPT the self identifier, and any
stored Splitwise tokens (so dev never re-imports real Splitwise over the seed). It never touches
accounts/transactions/plaid_items (the sandbox Plaid data stays) or receipts.

Usage (inside the DEV api container — never run against production):
    python -m app.cli.seed_dev --as matt --wipe
    python -m app.cli.seed_dev --as matt          # add a fresh synthetic set without wiping
"""
import argparse
import asyncio

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.dev_seed import generator
from app.models import (
    Expense,
    ExpenseItem,
    Group,
    GroupMember,
    Split,
    SplitwiseToken,
    User,
)
from app.models.enums import BackendType, UserSource


async def _wipe(session, self_identifier: str) -> None:
    # Groups cascade to expenses -> splits/items. Members, foreign users, and Splitwise tokens go too.
    await session.execute(delete(Group))
    await session.execute(delete(GroupMember))
    await session.execute(delete(SplitwiseToken))
    await session.execute(delete(User).where(User.identifier != self_identifier))
    await session.flush()


async def _ensure_user(session, u: generator.SeedUser) -> None:
    existing = await session.scalar(select(User).where(User.identifier == u.identifier))
    if existing is None:
        session.add(User(identifier=u.identifier, display_name=u.display_name,
                         source=UserSource(u.source)))


async def seed(session, *, self_identifier: str, wipe: bool, seed_value: int = 1234) -> dict:
    """Apply the synthetic seed to an open session (committed). Returns simple counts. Reused by tests."""
    data = generator.generate(self_identifier, seed=seed_value)
    if wipe:
        await _wipe(session, self_identifier)

    for u in data.users:
        await _ensure_user(session, u)
    await session.flush()

    expense_count = 0
    for g in data.groups:
        group = Group(name=g.name, backend_type=BackendType.self_hosted, group_type=g.group_type)
        session.add(group)
        await session.flush()  # assign group.id for members + expenses
        for ident in g.members:
            session.add(GroupMember(group_id=group.id, user_identifier=ident))
        for e in g.expenses:
            session.add(Expense(
                group_id=group.id, description=e.description, amount=e.amount,
                currency=e.currency, date=e.date, category=e.category, created_by=e.created_by,
                splits=[Split(user_identifier=s.user_identifier,
                              paid_share=s.paid_share, owed_share=s.owed_share) for s in e.splits],
                items=[ExpenseItem(name=i.name, quantity=i.quantity,
                                   price=i.price, category=i.category) for i in e.items],
            ))
            expense_count += 1

    await session.commit()
    return {"users": len(data.users), "groups": len(data.groups), "expenses": expense_count}


async def _run(args: argparse.Namespace) -> None:
    async with async_session() as session:
        stats = await seed(session, self_identifier=args.as_user, wipe=args.wipe, seed_value=args.seed)
    print(f"Seeded {stats['users']} users, {stats['groups']} groups, {stats['expenses']} expenses "
          f"(self={args.as_user}, wipe={args.wipe}).")


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed the dev backend with synthetic data.")
    parser.add_argument("--as", dest="as_user", default="matt",
                        help="your local identifier, kept verbatim so you sign in as yourself")
    parser.add_argument("--seed", type=int, default=1234, help="RNG seed (deterministic output)")
    parser.add_argument("--wipe", action="store_true",
                        help="clear the Splitwise side first (keeps accounts/transactions)")
    asyncio.run(_run(parser.parse_args()))


if __name__ == "__main__":
    main()
