"""Plaid re-link migration.

Re-linking a bank yields a NEW Plaid item with fresh account/transaction ids and ~24 months of history. This
merges that new item onto the user's existing one: it matches accounts (by mask, then name+type), carries over
each account's user customizations, and de-duplicates the overlapping recent transactions by content —
preserving category overrides, line items, and transaction<->expense links — so the backfill lands cleanly
with no duplicates. The matchers are pure (unit-tested); `migrate` does the DB work.
"""
from __future__ import annotations

import asyncio
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models import Account, Expense, PlaidItem, Transaction


def _norm(name: str | None) -> str:
    return (name or "").strip().lower()


def match_accounts(old: list[dict], new: list[dict]) -> list[tuple[dict, dict]]:
    """Greedy 1:1 pairing of old↔new Plaid account dicts (keys: plaid_account_id, name, type, mask):
    first by mask, then by name+type, then by name. Each new account is used at most once."""
    remaining = list(new)
    pairs: list[tuple[dict, dict]] = []

    def take(pred) -> dict | None:
        for i, candidate in enumerate(remaining):
            if pred(candidate):
                return remaining.pop(i)
        return None

    def sweep(items: list[dict], pred) -> list[dict]:
        leftovers: list[dict] = []
        for o in items:
            match = take(lambda n: pred(o, n))
            if match is None:
                leftovers.append(o)
            else:
                pairs.append((o, match))
        return leftovers

    after_mask = sweep(old, lambda o, n: bool(o.get("mask")) and n.get("mask") == o.get("mask"))
    after_name_type = sweep(after_mask,
                            lambda o, n: _norm(n["name"]) == _norm(o["name"])
                            and (n.get("type") or "") == (o.get("type") or ""))
    sweep(after_name_type, lambda o, n: _norm(n["name"]) == _norm(o["name"]))
    return pairs


def _txn_key(t) -> tuple:
    return (t.date, t.amount, _norm(t.description))


def match_transactions(old: list, new: list) -> tuple[list[tuple], list]:
    """Greedy pairing of old↔new transactions by (date, amount, description). Returns (pairs, unmatched_old);
    each new transaction matches at most one old."""
    buckets: dict[tuple, list] = {}
    for n in new:
        buckets.setdefault(_txn_key(n), []).append(n)
    pairs: list[tuple] = []
    unmatched_old: list = []
    for o in old:
        bucket = buckets.get(_txn_key(o))
        if bucket:
            pairs.append((o, bucket.pop()))
        else:
            unmatched_old.append(o)
    return pairs, unmatched_old


async def _accounts_by_plaid_id(session: AsyncSession, item_id: UUID) -> dict[str, Account]:
    rows = await session.scalars(select(Account).where(Account.plaid_item_id == item_id))
    return {a.plaid_account_id: a for a in rows}


async def _txns_for_account(session: AsyncSession, account_id: UUID) -> list[Transaction]:
    rows = await session.scalars(
        select(Transaction).where(Transaction.account_id == account_id)
        .options(selectinload(Transaction.items))
    )
    return list(rows)


async def migrate(session: AsyncSession, old_item: PlaidItem, new_item: PlaidItem, client) -> dict:
    """Merge `new_item` (freshly linked + fully synced) onto `old_item`, then delete `old_item`."""
    old_plaid = await asyncio.to_thread(client.get_accounts, old_item.access_token)
    new_plaid = await asyncio.to_thread(client.get_accounts, new_item.access_token)
    pairs = match_accounts(old_plaid, new_plaid)

    old_db = await _accounts_by_plaid_id(session, old_item.id)
    new_db = await _accounts_by_plaid_id(session, new_item.id)

    stats = {"accounts_matched": 0, "transactions_merged": 0, "transactions_kept": 0, "links_moved": 0}

    for o_pl, n_pl in pairs:
        o_acct = old_db.get(o_pl["plaid_account_id"])
        n_acct = new_db.get(n_pl["plaid_account_id"])
        if o_acct is None or n_acct is None:
            continue
        stats["accounts_matched"] += 1
        # Carry over the user's customizations onto the new account (Plaid sync doesn't touch these).
        n_acct.display_name = o_acct.display_name
        n_acct.kind = o_acct.kind
        n_acct.include_in_spending = o_acct.include_in_spending
        n_acct.include_in_cash_flow = o_acct.include_in_cash_flow

        o_txns = await _txns_for_account(session, o_acct.id)
        n_txns = await _txns_for_account(session, n_acct.id)
        txn_pairs, unmatched_old = match_transactions(o_txns, n_txns)

        for t_old, t_new in txn_pairs:
            if t_new.category_override is None and t_old.category_override is not None:
                t_new.category_override = t_old.category_override
            if not t_new.items and t_old.items:
                # Move via the relationship so delete-orphan doesn't reclaim them when t_old is deleted.
                for item in list(t_old.items):
                    t_old.items.remove(item)
                    t_new.items.append(item)
            result = await session.execute(
                update(Expense).where(Expense.transaction_id == t_old.id)
                .values(transaction_id=t_new.id)
            )
            stats["links_moved"] += result.rowcount or 0
            await session.delete(t_old)
            stats["transactions_merged"] += 1

        for t_old in unmatched_old:
            has_link = (await session.scalar(
                select(Expense.id).where(Expense.transaction_id == t_old.id).limit(1)
            )) is not None
            if has_link or t_old.category_override is not None or t_old.items:
                t_old.account_id = n_acct.id  # keep user-meaningful rows; re-parent onto the new account
                stats["transactions_kept"] += 1
            else:
                await session.delete(t_old)  # stale/pending duplicate — the new pull supersedes it

    # Unmatched old accounts (rare): detach from the old item so deleting it doesn't cascade their data away.
    matched_old_pids = {o_pl["plaid_account_id"] for o_pl, _ in pairs}
    for plaid_account_id, account in old_db.items():
        if plaid_account_id not in matched_old_pids:
            account.plaid_item_id = None

    await session.delete(old_item)  # matched old accounts are now empty → cascade removes them
    await session.commit()
    stats["items_synced"] = 1
    return stats
