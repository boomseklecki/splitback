"""Phase 4: server-side spend-by-category (solo) + the budget-nearing/over push hook. Covers the resolver/
include-flag/linked-expense-dedup paths, the status thresholds, and once-per-(goal,month,kind) firing gated by
`budget_push_enabled`. DB-backed (calls the service fns directly)."""
import uuid
from datetime import date
from decimal import Decimal

from sqlalchemy import delete, select

from app import server_settings
from app.db import async_session
from app.models import (
    Account, BackendType, Expense, Goal, GoalBudgetNotification, Group, GroupMember,
    Notification, Split, Transaction,
)
from app.models.enums import TransactionSource
from app.services import spend as spend_svc

OWNER = "spend-alice"
OTHER = "spend-bob"
_MONTH = date.today().replace(day=1)


def _mid_month() -> date:
    return _MONTH.replace(day=15)


async def _cleanup():
    async with async_session() as s:
        await s.execute(delete(GoalBudgetNotification).where(
            GoalBudgetNotification.owner_identifier == OWNER))
        await s.execute(delete(Notification).where(Notification.owner_identifier.in_([OWNER, OTHER])))
        await s.execute(delete(Goal).where(Goal.owner_identifier == OWNER))
        await s.execute(delete(Transaction).where(Transaction.owner_identifier == OWNER))
        # expenses/splits/groups cascade from the group
        gids = list(await s.scalars(select(Group.id).where(Group.name.like("spend-grp%"))))
        for gid in gids:
            await s.execute(delete(Group).where(Group.id == gid))
        await s.commit()


def test_budget_status_thresholds():
    assert spend_svc.budget_status(Decimal("90"), Decimal("100")) == "nearing"   # 90%
    assert spend_svc.budget_status(Decimal("84"), Decimal("100")) == "under"      # <85%
    assert spend_svc.budget_status(Decimal("120"), Decimal("100")) == "over"      # >100%
    assert spend_svc.budget_status(Decimal("0"), Decimal("0")) == "under"


async def test_spend_by_category_solo_and_account_default():
    await _cleanup()
    try:
        async with async_session() as s:
            acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                           owner_identifier=OWNER)
            s.add(acct)
            await s.flush()
            # FOOD_AND_DRINK → Dining (deterministic); a credit-card (liability) counts too.
            s.add(Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Dinner",
                              amount=Decimal("40.00"), currency="USD", date=_mid_month(),
                              category="FOOD_AND_DRINK", owner_identifier=OWNER))
            s.add(Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Lunch",
                              amount=Decimal("10.00"), currency="USD", date=_mid_month(),
                              category="FOOD_AND_DRINK_GROCERIES", owner_identifier=OWNER))
            # An income row (negative-ish category) is excluded from spend.
            s.add(Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Pay",
                              amount=Decimal("500.00"), currency="USD", date=_mid_month(),
                              category="INCOME", owner_identifier=OWNER))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.spend_by_category(s, OWNER, _MONTH)
        assert totals.get("Dining") == Decimal("40.00")
        assert totals.get("Groceries") == Decimal("10.00")
        assert "Income" not in totals
    finally:
        await _cleanup()


async def test_linked_expense_dedup():
    await _cleanup()
    try:
        async with async_session() as s:
            acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                           owner_identifier=OWNER)
            s.add(acct)
            await s.flush()
            txn = Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Rent",
                              amount=Decimal("2000.00"), currency="USD", date=_mid_month(),
                              category="RENT_AND_UTILITIES_RENT", owner_identifier=OWNER)
            s.add(txn)
            grp = Group(name="spend-grp-1", backend_type=BackendType.self_hosted)
            s.add(grp)
            await s.flush()
            s.add(GroupMember(group_id=grp.id, user_identifier=OWNER))
            exp = Expense(group_id=grp.id, transaction_id=txn.id, description="Rent split",
                          amount=Decimal("2000.00"), currency="USD", date=_mid_month(), category="Rent")
            s.add(exp)
            await s.flush()
            s.add(Split(expense_id=exp.id, user_identifier=OWNER, paid_share=Decimal("2000.00"),
                        owed_share=Decimal("1000.00")))
            await s.commit()
        async with async_session() as s:
            totals = await spend_svc.spend_by_category(s, OWNER, _MONTH)
        # The $2000 gross transaction is dropped in favor of the $1000 owed share — not $3000.
        assert totals.get("Rent") == Decimal("1000.00")
    finally:
        await _cleanup()


async def _seed_goal_and_spend(target: Decimal, txn_amount: Decimal):
    async with async_session() as s:
        acct = Account(name="Checking", type="checking", balance=Decimal(0), currency="USD",
                       owner_identifier=OWNER)
        s.add(acct)
        await s.flush()
        s.add(Transaction(account_id=acct.id, source=TransactionSource.plaid, description="Dinner",
                          amount=txn_amount, currency="USD", date=_mid_month(),
                          category="FOOD_AND_DRINK", owner_identifier=OWNER))
        s.add(Goal(kind="spend", name="Dining budget", owner_identifier=OWNER, category="Dining",
                   target_amount=target))
        await s.commit()


async def test_budget_push_once_per_month_and_escalates():
    await _cleanup()
    try:
        async with async_session() as s:
            await server_settings.set_value(s, "budget_push_enabled", True)
            await s.commit()
        await _seed_goal_and_spend(target=Decimal("100"), txn_amount=Decimal("90"))  # 90% → nearing

        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})
        async with async_session() as s:
            notifs = list(await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER)))
            markers = list(await s.scalars(select(GoalBudgetNotification).where(
                GoalBudgetNotification.owner_identifier == OWNER)))
        assert [n.type for n in notifs] == ["budget_nearing"]
        assert notifs[0].entity_type == "goal"
        assert {m.kind for m in markers} == {"nearing"}

        # Re-running the same month does not duplicate (marker present).
        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})
        async with async_session() as s:
            n = len(list(await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER))))
        assert n == 1  # still just the one nearing push

        # Crossing 100% fires a distinct "over" push (new kind), still once.
        async with async_session() as s:
            acct_id = await s.scalar(select(Account.id).where(Account.owner_identifier == OWNER))
            s.add(Transaction(account_id=acct_id, source=TransactionSource.plaid, description="More",
                              amount=Decimal("30.00"), currency="USD", date=_mid_month(),
                              category="FOOD_AND_DRINK", owner_identifier=OWNER))  # 120 > 100
            await s.commit()
        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})
        async with async_session() as s:
            kinds = sorted(m.kind for m in await s.scalars(select(GoalBudgetNotification).where(
                GoalBudgetNotification.owner_identifier == OWNER)))
            types = sorted(n.type for n in await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER)))
        assert kinds == ["nearing", "over"]
        assert types == ["budget_nearing", "budget_over"]
    finally:
        async with async_session() as s:
            await server_settings.set_value(s, "budget_push_enabled", False)
            await s.commit()
        await _cleanup()


async def test_budget_push_gated_off_by_default():
    await _cleanup()
    try:
        await _seed_goal_and_spend(target=Decimal("100"), txn_amount=Decimal("95"))
        async with async_session() as s:
            await spend_svc.evaluate_budget_push(s, {OWNER})  # flag default off
        async with async_session() as s:
            n = len(list(await s.scalars(select(Notification).where(
                Notification.owner_identifier == OWNER))))
        assert n == 0
    finally:
        await _cleanup()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
