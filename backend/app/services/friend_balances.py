"""Pairwise ("friends") balance computation — your net with each person, Splitwise-style.

For one expense, "X owes Y" = X's owed share covered by the payers in proportion to what they paid:
`X.owed_share * (Y.paid_share / total_paid)`. So the caller's net with person P from that expense is
`(P.owed_share * my.paid_share - my.owed_share * P.paid_share) / total_paid` — positive means P owes the
caller. Summed across every (non-archived) expense in the caller's groups. Settle-ups are modeled as normal
splits (the payer has paid_share, the recipient owed_share), so they net the pair toward zero automatically.

Pure (no DB) so it's unit-testable; the router supplies the expenses + splits.
"""
from collections import defaultdict
from decimal import Decimal


def compute(caller: str, expenses) -> dict[str, Decimal]:
    """Net balance between `caller` and each other person, across `expenses` (each with `.splits`, and each
    split exposing `user_identifier`, `paid_share`, `owed_share`). Positive net = that person owes the caller.
    Only people who share an expense with the caller appear."""
    nets: dict[str, Decimal] = defaultdict(lambda: Decimal(0))
    for expense in expenses:
        splits = list(expense.splits)
        total_paid = sum((s.paid_share for s in splits), Decimal(0))
        if total_paid == 0:
            continue
        mine = next((s for s in splits if s.user_identifier == caller), None)
        if mine is None:
            continue  # caller isn't in this expense → no effect on their pairwise balances
        for s in splits:
            if s.user_identifier == caller:
                continue
            nets[s.user_identifier] += (
                s.owed_share * mine.paid_share - mine.owed_share * s.paid_share
            ) / total_paid
    return dict(nets)
