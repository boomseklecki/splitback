"""Dev synthetic seed: pure generator invariants + the seeder's wipe scope.

NOTE: test_seed_wipe_preserves_bank_data is DESTRUCTIVE (the seeder's --wipe clears groups/users/Splitwise
tokens). It is meant for the ephemeral test DB (api-test/db-test), never production.
"""
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, func, select

from app.cli.seed_dev import seed
from app.db import async_session
from app.integrations.dev_seed import generator
from app.models import Account, Group, SplitwiseToken, Transaction, User
from app.models.enums import TransactionSource


def test_generator_deterministic_and_balanced():
    a = generator.generate("matt", seed=1234, today=date(2026, 6, 20))
    b = generator.generate("matt", seed=1234, today=date(2026, 6, 20))

    def shape(d):
        return [(g.name, [(e.description, str(e.amount)) for e in g.expenses]) for g in d.groups]

    assert shape(a) == shape(b)  # deterministic

    # self kept verbatim as an app user; everyone else invented
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
            if e.items:  # itemized expenses' items sum to the amount
                assert sum((i.price for i in e.items), Decimal(0)) == e.amount


async def test_seed_wipe_preserves_bank_data():
    acct_id = None
    try:
        # Pre-existing state: a bank account + transaction (must survive), a foreign user + a Splitwise
        # token (must be wiped).
        async with async_session() as session:
            account = Account(name="Sandbox Checking", balance=Decimal("100.00"))
            session.add(account)
            await session.flush()
            acct_id = account.id
            session.add(Transaction(account_id=account.id, source=TransactionSource.manual,
                                    description="Coffee", amount=Decimal("4.50"), date=date.today()))
            session.add(User(identifier="stranger", display_name="Stranger", source="splitwise"))
            session.add(SplitwiseToken(user_identifier="matt", access_token="real-secret-token"))
            await session.commit()

        async with async_session() as session:
            stats = await seed(session, self_identifier="matt", wipe=True)
        assert stats["groups"] == 2 and stats["expenses"] > 0

        async with async_session() as session:
            # Bank data untouched.
            assert await session.get(Account, acct_id) is not None
            assert await session.scalar(select(func.count()).select_from(Transaction)) >= 1
            # Splitwise side reset: token gone, foreign user gone, self kept, synthetic groups present.
            assert await session.scalar(select(func.count()).select_from(SplitwiseToken)) == 0
            assert await session.scalar(select(User).where(User.identifier == "stranger")) is None
            assert await session.scalar(select(User).where(User.identifier == "matt")) is not None
            assert await session.scalar(select(func.count()).select_from(Group)) == 2
    finally:
        async with async_session() as session:
            await session.execute(delete(Transaction))
            await session.execute(delete(Group))
            await session.execute(delete(User))
            await session.execute(delete(SplitwiseToken))
            if acct_id:
                await session.execute(delete(Account).where(Account.id == acct_id))
            await session.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
