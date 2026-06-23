"""Pure unit tests for Plaid re-link matching (no DB / no Plaid)."""
from datetime import date
from decimal import Decimal
from types import SimpleNamespace

from app.services.plaid_relink import match_accounts, match_transactions


def _acct(pid, name, type_, mask):
    return {"plaid_account_id": pid, "name": name, "type": type_, "mask": mask}


def test_match_accounts_by_mask():
    old = [_acct("o1", "Checking", "checking", "1234"), _acct("o2", "Savings", "savings", "5678")]
    new = [_acct("n2", "SAVINGS ACCT", "savings", "5678"), _acct("n1", "CHK", "checking", "1234")]
    pairs = {o["plaid_account_id"]: n["plaid_account_id"] for o, n in match_accounts(old, new)}
    assert pairs == {"o1": "n1", "o2": "n2"}  # mask wins regardless of name/order


def test_match_accounts_name_type_fallback_when_mask_missing():
    old = [_acct("o1", "Checking", "checking", None)]
    new = [_acct("n1", "checking", "checking", None), _acct("n2", "Checking", "savings", None)]
    pairs = match_accounts(old, new)
    assert len(pairs) == 1 and pairs[0][1]["plaid_account_id"] == "n1"  # name+type, not name+wrong-type


def test_match_accounts_unpaired_left_out():
    old = [_acct("o1", "Checking", "checking", "1111"), _acct("o2", "Old Closed", "checking", "9999")]
    new = [_acct("n1", "Checking", "checking", "1111")]
    pairs = match_accounts(old, new)
    assert len(pairs) == 1 and pairs[0][0]["plaid_account_id"] == "o1"


def _txn(d, amount, desc):
    return SimpleNamespace(date=d, amount=Decimal(amount), description=desc)


def test_match_transactions_pairs_and_unmatched():
    d = date(2026, 6, 1)
    old = [_txn(d, "12.00", "NETFLIX"), _txn(d, "9.99", "SPOTIFY"), _txn(d, "5.00", "GONE")]
    new = [_txn(d, "9.99", "spotify"), _txn(d, "12.00", "netflix"), _txn(d, "3.00", "NEW")]
    pairs, unmatched = match_transactions(old, new)
    paired_old = {p[0].description for p in pairs}
    assert paired_old == {"NETFLIX", "SPOTIFY"}      # case-insensitive (date+amount+desc)
    assert [t.description for t in unmatched] == ["GONE"]


def test_match_transactions_duplicates_consumed_one_to_one():
    d = date(2026, 6, 1)
    old = [_txn(d, "4.00", "COFFEE"), _txn(d, "4.00", "COFFEE")]
    new = [_txn(d, "4.00", "COFFEE")]                 # only one new copy
    pairs, unmatched = match_transactions(old, new)
    assert len(pairs) == 1 and len(unmatched) == 1    # second old stays unmatched (no double-claim)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
