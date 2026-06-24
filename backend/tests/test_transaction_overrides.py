"""Per-(owner, transaction) category override: set/clear via PATCH, scoped to the caller. DB-backed."""
import uuid
from datetime import date

from sqlalchemy import delete, select

from app.db import async_session
from app.models import Transaction, TransactionCategoryOverride
from app.routers.accounts import _load_transaction, update_transaction
from app.schemas.transaction import TransactionUpdate


async def _make_txn(session, owner: str) -> uuid.UUID:
    txn = Transaction(
        source="manual", description="Coffee", amount=4, currency="USD", date=date(2026, 6, 1),
        owner_identifier=owner,
    )
    session.add(txn)
    await session.commit()
    return txn.id


async def _cleanup(session, txn_id):
    await session.execute(
        delete(TransactionCategoryOverride).where(TransactionCategoryOverride.transaction_id == txn_id)
    )
    await session.execute(delete(Transaction).where(Transaction.id == txn_id))
    await session.commit()


async def test_set_then_clear_override():
    async with async_session() as s:
        txn_id = await _make_txn(s, "alice")
        try:
            await update_transaction(txn_id, TransactionUpdate(category_override="Dining"),
                                     caller="alice", session=s)
            t = await _load_transaction(s, txn_id, "alice")
            assert t.category_override == "Dining"
            # A second update replaces it.
            await update_transaction(txn_id, TransactionUpdate(category_override="Groceries"),
                                     caller="alice", session=s)
            assert (await _load_transaction(s, txn_id, "alice")).category_override == "Groceries"
            # null clears it (row deleted).
            await update_transaction(txn_id, TransactionUpdate(category_override=None),
                                     caller="alice", session=s)
            assert (await _load_transaction(s, txn_id, "alice")).category_override is None
            assert (await s.scalar(select(TransactionCategoryOverride).where(
                TransactionCategoryOverride.transaction_id == txn_id))) is None
        finally:
            await _cleanup(s, txn_id)


async def test_override_scoped_per_owner():
    async with async_session() as s:
        txn_id = await _make_txn(s, "alice")
        try:
            await update_transaction(txn_id, TransactionUpdate(category_override="Dining"),
                                     caller="alice", session=s)
            # Bob (a different caller) sees no override on the same transaction row.
            assert (await _load_transaction(s, txn_id, "bob")).category_override is None
            assert (await _load_transaction(s, txn_id, "alice")).category_override == "Dining"
        finally:
            await _cleanup(s, txn_id)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
