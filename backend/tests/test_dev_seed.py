"""Dev synthetic seed: pure generator invariants + the seeder's wipe scope.

NOTE: test_seed_wipe is DESTRUCTIVE (the seeder's --wipe clears groups/users/Splitwise tokens + synthetic
personal data). It is meant for the ephemeral test DB (api-test/db-test), never production.
"""
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.categories import CATEGORIES
from app.cli.seed_dev import seed
from app.db import async_session
from app.integrations.dev_seed import generator
from app.models import (
    Account,
    Goal,
    Group,
    GroupMember,
    PlaidItem,
    SplitwiseToken,
    Transaction,
    User,
)
from app.models.enums import TransactionSource


def test_generator_deterministic_and_balanced():
    a = generator.generate("matt", seed=1234, today=date(2026, 6, 20))
    b = generator.generate("matt", seed=1234, today=date(2026, 6, 20))

    def shape(d):
        return (
            [(g.name, [(e.description, str(e.amount)) for e in g.expenses]) for g in d.groups],
            [(t.description, str(t.amount)) for t in d.transactions],
        )

    assert shape(a) == shape(b)  # deterministic, incl. personal transactions

    you = [u for u in a.users if u.identifier == "matt"]
    assert you and you[0].source == "app"

    for g in a.groups:
        assert g.expenses
        for e in g.expenses:
            paid = sum((s.paid_share for s in e.splits), Decimal(0))
            owed = sum((s.owed_share for s in e.splits), Decimal(0))
            assert abs(paid - e.amount) <= Decimal("0.01")
            assert abs(owed - e.amount) <= Decimal("0.01")
            assert {s.user_identifier for s in e.splits} <= set(g.members)
            if e.items:
                assert sum((i.price for i in e.items), Decimal(0)) == e.amount

    # Personal finances for EVERY persona: 3 accounts + 2 goals each, owner-consistent, valid categories,
    # ≥1 income inflow. Account keys are owner-prefixed; transactions/goals stay within their owner.
    owners = {u.identifier for u in a.users}
    by_key = {acc.key: acc.owner for acc in a.accounts}
    assert {acc.owner for acc in a.accounts} == owners            # everyone has accounts
    assert len(a.accounts) == 3 * len(a.users)
    assert all(acc.key.startswith(f"{acc.owner}:") for acc in a.accounts)
    assert a.transactions and any(t.amount < 0 for t in a.transactions)
    assert {t.category for t in a.transactions} <= set(CATEGORIES)
    assert all(by_key[t.account_key] == t.owner for t in a.transactions if t.account_key)
    save = [g for g in a.goals if g.kind == "save"]
    assert len(a.goals) == 2 * len(a.users)
    assert all(by_key[s.account_key] == s.owner for s in save)   # save goal -> own account


async def test_seed_wipe_resets_synthetic_keeps_plaid():
    try:
        async with async_session() as session:
            # Plaid-linked account + transaction (MUST survive --wipe).
            item = PlaidItem(plaid_item_id="seed-item-zzz", access_token="x", user_identifier="matt")
            session.add(item)
            await session.flush()
            linked = Account(name="Linked ZZZ", balance=Decimal("100"),
                             plaid_item_id=item.id, owner_identifier="matt")
            session.add(linked)
            await session.flush()
            session.add(Transaction(account_id=linked.id, source=TransactionSource.plaid,
                                    plaid_transaction_id="seed-tx-zzz", description="Coffee",
                                    amount=Decimal("4.50"), date=date.today(), owner_identifier="matt"))
            # Manual account (MUST be wiped), plus a stranger + Splitwise token.
            session.add(Account(name="Manual ZZZ", balance=Decimal("5"), owner_identifier="matt"))
            session.add(User(identifier="stranger", display_name="Stranger", source="splitwise"))
            session.add(SplitwiseToken(user_identifier="matt", access_token="real-secret-token"))
            await session.commit()

        async with async_session() as session:
            stats = await seed(session, self_identifier="matt", wipe=True)
        assert stats["groups"] == 2 and stats["expenses"] > 0
        # Every persona gets 3 accounts + 2 goals.
        assert stats["accounts"] == 3 * stats["users"] and stats["transactions"] > 0
        assert stats["goals"] == 2 * stats["users"]

        async with async_session() as session:
            # Plaid-linked survives; manual gone; Splitwise reset; self kept.
            assert await session.scalar(
                select(func.count()).select_from(Transaction)
                .where(Transaction.plaid_transaction_id == "seed-tx-zzz")) == 1
            assert await session.scalar(
                select(func.count()).select_from(Account).where(Account.name == "Linked ZZZ")) == 1
            assert await session.scalar(
                select(func.count()).select_from(Account).where(Account.name == "Manual ZZZ")) == 0
            assert await session.scalar(select(func.count()).select_from(SplitwiseToken)) == 0
            assert await session.scalar(select(User).where(User.identifier == "stranger")) is None
            assert await session.scalar(select(User).where(User.identifier == "matt")) is not None
            # Synthetic personal data present per persona (matt AND a fake member each own accounts/goals).
            for ident in ("matt", "robin"):
                assert await session.scalar(
                    select(func.count()).select_from(Account)
                    .where(Account.owner_identifier == ident, Account.plaid_item_id.is_(None))) == 3
                assert await session.scalar(
                    select(func.count()).select_from(Goal).where(Goal.owner_identifier == ident)) == 2
    finally:
        async with async_session() as session:
            for model in (Goal, Transaction, GroupMember, Group, Account, PlaidItem, SplitwiseToken):
                await session.execute(delete(model))
            await session.execute(delete(User).where(
                User.identifier.in_(["matt", "robin", "sam", "alex", "stranger"])))
            await session.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
