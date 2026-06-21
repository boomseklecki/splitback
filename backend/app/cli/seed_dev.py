"""Seed the DEVELOPMENT backend with synthetic data: Splitwise-style groups/expenses PLUS personal
accounts/transactions/goals owned by the self identifier, so impersonating that user (via an API_TOKENS
mapping) shows a fully-populated app — Accounts/Splits/Goals/Trends with correct balances.

With --wipe it resets to a clean synthetic state: all groups (cascading expenses/splits/items), group
members, every user EXCEPT the self identifier, stored Splitwise tokens, AND the synthetic personal data
(manual accounts — plaid_item_id NULL — with their transactions, plus goals). It NEVER touches Plaid-linked
accounts/transactions/plaid_items (sandbox banks a tester linked stay) or receipts.

Usage (inside the DEV api container — never run against production):
    python -m app.cli.seed_dev --as matt --wipe
    python -m app.cli.seed_dev --as matt          # add a fresh synthetic set without wiping
"""
import argparse
import asyncio
from uuid import UUID

from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.dev_seed import generator
from app.models import (
    Account,
    Expense,
    ExpenseItem,
    Goal,
    Group,
    GroupMember,
    Split,
    SplitwiseToken,
    Transaction,
    User,
)
from app.models.enums import BackendType, TransactionSource, UserSource


async def _wipe(session, self_identifier: str) -> None:
    # Groups cascade to expenses -> splits/items. Members, foreign users, and Splitwise tokens go too.
    await session.execute(delete(Group))
    await session.execute(delete(GroupMember))
    await session.execute(delete(SplitwiseToken))
    await session.execute(delete(User).where(User.identifier != self_identifier))
    # Synthetic personal data: goals + manual (non-Plaid) accounts and their transactions. Plaid-linked
    # accounts/transactions (a tester's sandbox banks) are left untouched.
    await session.execute(delete(Goal))
    manual_accounts = select(Account.id).where(Account.plaid_item_id.is_(None))
    await session.execute(delete(Transaction).where(Transaction.account_id.in_(manual_accounts)))
    await session.execute(delete(Account).where(Account.plaid_item_id.is_(None)))
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

    # Personal finances, each owned by its persona (so per-caller scoping shows them to that user — every
    # impersonation token lands in a populated app).
    account_ids: dict[str, UUID] = {}
    for a in data.accounts:
        account = Account(name=a.name, type=a.type, balance=a.balance, currency="USD",
                          owner_identifier=a.owner)
        session.add(account)
        await session.flush()
        account_ids[a.key] = account.id
    for t in data.transactions:
        session.add(Transaction(
            account_id=account_ids.get(t.account_key) if t.account_key else None,
            source=TransactionSource.manual, description=t.description, amount=t.amount,
            currency=t.currency, date=t.date, category=t.category,
            owner_identifier=t.owner))
    for go in data.goals:
        session.add(Goal(
            kind=go.kind, name=go.name, category=go.category,
            account_id=account_ids.get(go.account_key) if go.account_key else None,
            target_amount=go.target_amount, save_target_type=go.save_target_type,
            starting_balance=go.starting_balance, owner_identifier=go.owner))

    await session.commit()
    return {
        "users": len(data.users), "groups": len(data.groups), "expenses": expense_count,
        "accounts": len(data.accounts), "transactions": len(data.transactions), "goals": len(data.goals),
    }


async def _run(args: argparse.Namespace) -> None:
    async with async_session() as session:
        stats = await seed(session, self_identifier=args.as_user, wipe=args.wipe, seed_value=args.seed)
    print(f"Seeded {stats['users']} users, {stats['groups']} groups, {stats['expenses']} expenses, "
          f"{stats['accounts']} accounts, {stats['transactions']} transactions, {stats['goals']} goals "
          f"(self={args.as_user}, wipe={args.wipe}).")


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed the dev backend with synthetic data.")
    parser.add_argument("--as", dest="as_user", default="matt",
                        help="your local identifier, kept verbatim so you sign in as yourself")
    parser.add_argument("--seed", type=int, default=1234, help="RNG seed (deterministic output)")
    parser.add_argument("--wipe", action="store_true",
                        help="reset synthetic data first (keeps Plaid-linked accounts/transactions)")
    asyncio.run(_run(parser.parse_args()))


if __name__ == "__main__":
    main()
