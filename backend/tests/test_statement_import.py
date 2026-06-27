"""OFX statement import: find-or-creates a manual account, inserts transactions, and de-dups by FITID on
re-import. DB-backed, calling the import function directly."""
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.models import Account, Transaction
from app.routers.statements import import_ofx
from tests.test_ofx_parser import SAMPLE

OWNER = "stmt-owner"


async def _purge():
    async with async_session() as s:
        acct_ids = (await s.scalars(select(Account.id).where(Account.owner_identifier == OWNER))).all()
        if acct_ids:
            await s.execute(delete(Transaction).where(Transaction.account_id.in_(acct_ids)))
        await s.execute(delete(Account).where(Account.owner_identifier == OWNER))
        await s.commit()


async def test_import_creates_account_and_transactions():
    await _purge()
    try:
        async with async_session() as s:
            result = await import_ofx(s, OWNER, SAMPLE.encode())
        assert result.imported == 3 and result.total == 3 and result.skipped == 0
        assert result.account_name == "Apple Card"
        async with async_session() as s:
            acct = await s.get(Account, result.account_id)
            assert acct.owner_identifier == OWNER and acct.plaid_account_id is None and acct.mask == "4321"
            txns = (await s.scalars(select(Transaction).where(Transaction.account_id == acct.id))).all()
            assert len(txns) == 3
            byid = {t.external_transaction_id: t for t in txns}
            assert byid["AC-1"].amount == Decimal("42.50")     # purchase → outflow positive
            assert byid["AC-3"].amount == Decimal("-200.00")   # payment → inflow negative
            assert byid["AC-1"].source.value == "manual"
    finally:
        await _purge()


async def test_reimport_dedups_by_fitid():
    await _purge()
    try:
        async with async_session() as s:
            first = await import_ofx(s, OWNER, SAMPLE.encode())
        async with async_session() as s:
            second = await import_ofx(s, OWNER, SAMPLE.encode())  # same statement again
        assert first.imported == 3
        assert second.imported == 0 and second.skipped == 3      # nothing new, all de-duped
        assert second.account_id == first.account_id             # reused the same account
        async with async_session() as s:
            count = len((await s.scalars(
                select(Transaction).where(Transaction.account_id == first.account_id))).all())
        assert count == 3                                        # no duplicates
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
