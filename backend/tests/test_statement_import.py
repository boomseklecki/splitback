"""OFX statement import: find-or-creates a manual account (keyed on ACCTID), maps institution + balances, and
de-dups transactions by FITID on re-import. Balances follow the newest DTASOF. DB-backed."""
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app.db import async_session
from app.models import Account, Transaction
from app.routers.statements import import_ofx
from tests.test_ofx_parser import SAMPLE

OWNER = "stmt-owner"


def _variant(dtasof: str, ledger: str) -> bytes:
    """SAMPLE with a different statement DTASOF + LEDGERBAL (same ACCTID → same account)."""
    return SAMPLE.replace("20260626120000", dtasof + "120000").replace("-621.28", ledger).encode()


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
            assert acct.owner_identifier == OWNER and acct.plaid_account_id is None
            assert acct.external_account_id == "xxxxxxxxxxxx4321"   # find-or-create key (ACCTID)
            assert acct.institution_name == "Apple Card" and acct.institution_domain == "apple.com"
            assert acct.balance == Decimal("621.28")               # LEDGERBAL -621.28 flipped → positive owed
            assert acct.available_balance == Decimal("7878.72")    # AVAILBAL as-is
            assert acct.balance_as_of == date(2026, 6, 26)
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


async def test_balance_follows_newest_statement():
    await _purge()
    try:
        async with async_session() as s:
            r = await import_ofx(s, OWNER, SAMPLE.encode())                 # DTASOF 06-26 → balance 621.28
        async with async_session() as s:
            await import_ofx(s, OWNER, _variant("20260526", "-999.99"))     # OLDER → must not regress
        async with async_session() as s:
            acct = await s.get(Account, r.account_id)
            assert acct.balance == Decimal("621.28") and acct.balance_as_of == date(2026, 6, 26)
        async with async_session() as s:
            await import_ofx(s, OWNER, _variant("20260726", "-100.00"))     # NEWER → adopted
        async with async_session() as s:
            acct = await s.get(Account, r.account_id)
            assert acct.balance == Decimal("100.00") and acct.balance_as_of == date(2026, 7, 26)
    finally:
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
