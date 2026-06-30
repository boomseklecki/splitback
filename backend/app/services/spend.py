"""Server-side spend-by-category for a single owner — the solo slice of iOS `SpendingAnalytics`/`GoalProgress`,
enough to drive the budget-nearing/over push when the app is closed (the on-device number stays authoritative
on tap). Reuses the `CategoryResolver` + `category_builtin` spend-class sets so it agrees with the app.

Faithful to the app on the dominant path: linked-expense dedup (a Plaid transaction linked to a Splitwise
expense counts as the owed share, not the gross), per-user include flags (transaction→account, expense→group),
account-classification defaults, and EXCLUDED/NEUTRAL filtering. **Deferred** (Phase-4 scope): itemized
attribution (uses the whole-row category) and shared/household budgets (`HouseholdBudget`).
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

import logging
from datetime import date as _date

from .. import server_settings
from ..category_builtin import EXCLUDED_FROM_SPEND, NEUTRAL
from ..models.account import Account
from ..models.account_override import AccountOverride
from ..models.enums import TransactionSource
from ..models.expense import Expense
from ..models.expense_override import ExpenseOverride
from ..models.goal import Goal
from ..models.goal_budget_notification import GoalBudgetNotification
from ..models.group_override import GroupOverride
from ..models.transaction import Transaction
from ..models.transaction_override import TransactionOverride
from . import notify as notify_svc
from .category_resolver import CategoryResolver

log = logging.getLogger(__name__)

# Account classification (mirrors iOS AccountClassification): which kinds count toward spend.
_LIABILITY_SUBTYPES = {
    "credit card", "credit", "loan", "auto", "business", "commercial", "construction", "consumer",
    "home equity", "line of credit", "mortgage", "overdraft", "student",
}
_HOLDINGS_SUBTYPES = {
    "investment", "brokerage", "cd", "hsa", "ira", "roth", "roth ira", "sep ira", "simple ira",
    "401k", "401a", "403b", "457b", "529", "roth 401k", "mutual fund", "stock plan", "pension",
    "retirement", "keogh", "thrift savings plan", "tfsa", "rrsp", "rrif", "lira", "resp", "trust",
}


def _classify(account_type: str | None) -> str:
    key = (account_type or "").lower()
    if key in _LIABILITY_SUBTYPES:
        return "liability"
    if key in _HOLDINGS_SUBTYPES:
        return "savings"
    return "cash_flow"


def _account_counts_in_spending(account: Account | None, override: AccountOverride | None) -> bool:
    """Mirrors `Account.countsInSpending`: the per-account override wins, else cash-flow + liability count."""
    if override is not None and override.include_in_spending is not None:
        return override.include_in_spending
    kind = (override.kind if override and override.kind else None) or _classify(
        account.type if account else None)
    return kind in ("cash_flow", "liability")


def budget_status(spent: Decimal, target: Decimal) -> str:
    """`"under"` / `"nearing"` (≥85%) / `"over"` (>100%) — mirrors `GoalProgress.budgetStatus`."""
    if target <= 0:
        return "over" if spent > 0 else "under"
    if spent > target:
        return "over"
    return "nearing" if (spent / target) >= Decimal("0.85") else "under"


def month_bounds(month: date) -> tuple[date, date]:
    """First-of-month (inclusive) → first-of-next-month (exclusive)."""
    start = month.replace(day=1)
    end = start.replace(year=start.year + 1, month=1) if start.month == 12 else start.replace(
        month=start.month + 1)
    return start, end


async def spend_by_category(session: AsyncSession, owner: str | None, month: date) -> dict[str, Decimal]:
    """Outflow spend per canonical category for `owner` in `month`'s calendar month."""
    if owner is None:
        return {}
    start, end = month_bounds(month)
    resolver = await CategoryResolver.for_owner(session, owner)
    totals: dict[str, Decimal] = defaultdict(Decimal)

    accounts = {a.id: a for a in await session.scalars(
        select(Account).where(Account.owner_identifier == owner))}
    acct_ovr = {o.account_id: o for o in await session.scalars(
        select(AccountOverride).where(AccountOverride.owner_identifier == owner))}
    txn_ovr = {o.transaction_id: o for o in await session.scalars(
        select(TransactionOverride).where(TransactionOverride.owner_identifier == owner))}
    # Transactions a (any) expense links to: their gross side is dropped for the expense's owed share.
    linked = set(await session.scalars(
        select(Expense.transaction_id).where(Expense.transaction_id.is_not(None))))

    txns = await session.scalars(select(Transaction).where(
        Transaction.owner_identifier == owner, Transaction.date >= start, Transaction.date < end))
    for t in txns:
        if t.id in linked:
            continue
        account = accounts.get(t.account_id) if t.account_id else None
        if t.source == TransactionSource.plaid and account is None:
            continue
        o = txn_ovr.get(t.id)
        in_spending = (o.include_in_spending if o is not None and o.include_in_spending is not None
                       else _account_counts_in_spending(account, acct_ovr.get(t.account_id)))
        if not in_spending or t.amount is None or t.amount <= 0:
            continue
        res = resolver.resolve(t.category, override=(o.category if o else None),
                               refined=(o.refined_category if o else None))
        if not res.category or res.category in EXCLUDED_FROM_SPEND:
            continue
        totals[res.category] += t.amount

    exp_ovr = {o.expense_id: o for o in await session.scalars(
        select(ExpenseOverride).where(ExpenseOverride.owner_identifier == owner))}
    grp_ovr = {o.group_id: o for o in await session.scalars(
        select(GroupOverride).where(GroupOverride.owner_identifier == owner))}
    exps = await session.scalars(select(Expense).options(selectinload(Expense.splits)).where(
        Expense.date >= start, Expense.date < end))
    for e in exps:
        mine = next((s for s in e.splits if s.user_identifier == owner), None)
        if mine is None:
            continue
        res = resolver.resolve_expense(e.category)
        cat = res.category
        if not cat or cat in NEUTRAL or cat in EXCLUDED_FROM_SPEND:
            continue
        eo = exp_ovr.get(e.id)
        go = grp_ovr.get(e.group_id)
        inc = (eo.include_in_spending if eo is not None and eo.include_in_spending is not None
               else (go.include_in_spending if go is not None and go.include_in_spending is not None
                     else True))
        if not inc:
            continue
        share = mine.owed_share or Decimal(0)
        if share <= 0:
            continue
        totals[cat] += share

    return dict(totals)


_KIND_LABEL = {"nearing": "approaching", "over": "over"}


async def evaluate_budget_push(session: AsyncSession, owners: set[str]) -> None:
    """For each owner's active **solo spend** goals, fire a budget push once per (goal, month, threshold) when
    the current month's spend crosses 85% (nearing) / 100% (over). Gated by `budget_push_enabled`. Isolated +
    best-effort: never raises (so it can't break the sync that called it). Household/itemized goals deferred."""
    if not owners:
        return
    try:
        if not bool(await server_settings.get(session, "budget_push_enabled")):
            return
        today = _date.today()
        month = today.replace(day=1)
        for owner in owners:
            goals = list(await session.scalars(select(Goal).where(
                Goal.owner_identifier == owner, Goal.kind == "spend", Goal.archived_at.is_(None),
                Goal.shared.is_(False), Goal.category.is_not(None))))
            if not goals:
                continue
            spent = await spend_by_category(session, owner, month)
            for goal in goals:
                status = budget_status(spent.get(goal.category, Decimal(0)), goal.target_amount)
                if status not in ("nearing", "over"):
                    continue
                existing = await session.scalar(select(GoalBudgetNotification).where(
                    GoalBudgetNotification.goal_id == goal.id,
                    GoalBudgetNotification.period_month == month,
                    GoalBudgetNotification.kind == status))
                if existing is not None:
                    continue
                session.add(GoalBudgetNotification(
                    owner_identifier=owner, goal_id=goal.id, period_month=month, kind=status))
                verb = _KIND_LABEL[status]
                content = (f"You're {verb} your {goal.category} budget this month."
                           if status == "over"
                           else f"You're {verb} your {goal.category} budget ({goal.name}) this month.")
                # notify() commits — flushing the marker added above in the same transaction.
                await notify_svc.notify(
                    session, {owner}, type=f"budget_{status}", content=content,
                    entity_type="goal", entity_id=str(goal.id))
    except Exception:
        log.exception("evaluate_budget_push failed")
        await session.rollback()
