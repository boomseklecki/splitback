"""Idempotent per-identity synthetic seed — reused by the dev CLI and the demo guest login.

`seed_identity` gives one local identifier a populated, *isolated* sample app: a couple of shared-expense
groups (with synthetic co-members so names render), their expenses, and that identity's own accounts/
transactions/goals. Per-caller scoping then shows each identity only their own data.
"""
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.dev_seed import generator
from app.models import (
    Account,
    Expense,
    ExpenseItem,
    Goal,
    Group,
    GroupMember,
    Split,
    Transaction,
    User,
)
from app.models.enums import BackendType, TransactionSource, UserSource


async def _ensure_user(session: AsyncSession, u: generator.SeedUser) -> None:
    if await session.scalar(select(User.id).where(User.identifier == u.identifier)) is None:
        session.add(User(identifier=u.identifier, display_name=u.display_name,
                         source=UserSource(u.source)))


async def seed_identity(session: AsyncSession, identifier: str, *, seed_value: int = 1234) -> bool:
    """Seed a populated isolated sample app for `identifier`. Idempotent: returns False (no-op) if the
    identity already has accounts. Flushes but does NOT commit — the caller commits."""
    if await session.scalar(
        select(func.count()).select_from(Account).where(Account.owner_identifier == identifier)
    ):
        return False

    data = generator.generate(identifier, seed=seed_value)

    for u in data.users:  # the identity (already exists) + shared synthetic co-members (idempotent)
        await _ensure_user(session, u)
    await session.flush()

    for g in data.groups:  # groups are built around `identifier` as a member
        group = Group(name=g.name, backend_type=BackendType.self_hosted, group_type=g.group_type)
        session.add(group)
        await session.flush()
        for ident in g.members:
            session.add(GroupMember(group_id=group.id, user_identifier=ident))
        for e in g.expenses:
            session.add(Expense(
                group_id=group.id, description=e.description, amount=e.amount, currency=e.currency,
                date=e.date, category=e.category, created_by=e.created_by,
                splits=[Split(user_identifier=s.user_identifier, paid_share=s.paid_share,
                              owed_share=s.owed_share) for s in e.splits],
                items=[ExpenseItem(name=i.name, quantity=i.quantity, price=i.price, category=i.category)
                       for i in e.items],
            ))

    # Only this identity's personal finances (the co-members stay directory-only).
    account_ids: dict[str, UUID] = {}
    for a in (x for x in data.accounts if x.owner == identifier):
        account = Account(name=a.name, type=a.type, balance=a.balance, currency="USD",
                          owner_identifier=identifier)
        session.add(account)
        await session.flush()
        account_ids[a.key] = account.id
    for t in (x for x in data.transactions if x.owner == identifier):
        session.add(Transaction(
            account_id=account_ids.get(t.account_key) if t.account_key else None,
            source=TransactionSource.manual, description=t.description, amount=t.amount,
            currency=t.currency, date=t.date, category=t.category, owner_identifier=identifier))
    for go in (x for x in data.goals if x.owner == identifier):
        session.add(Goal(
            kind=go.kind, name=go.name, category=go.category,
            account_id=account_ids.get(go.account_key) if go.account_key else None,
            target_amount=go.target_amount, save_target_type=go.save_target_type,
            starting_balance=go.starting_balance, owner_identifier=identifier))
    await session.flush()
    return True
