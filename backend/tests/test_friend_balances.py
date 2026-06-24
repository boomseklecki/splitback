"""Pure unit tests for pairwise ('friends') balance computation (no DB)."""
from decimal import Decimal
from types import SimpleNamespace

from app.services.friend_balances import compute


def _split(user, paid, owed):
    return SimpleNamespace(user_identifier=user, paid_share=Decimal(paid), owed_share=Decimal(owed))


def _expense(*splits):
    return SimpleNamespace(splits=list(splits))


def test_two_person_bill():
    # me paid $20, split evenly: me owes 10, P owes 10 -> P owes me 10.
    exp = _expense(_split("me", "20", "10"), _split("p", "0", "10"))
    assert compute("me", [exp]) == {"p": Decimal(10)}


def test_i_owe_when_they_paid():
    # P paid $20, even split -> I owe P 10 (negative).
    exp = _expense(_split("p", "20", "10"), _split("me", "0", "10"))
    assert compute("me", [exp]) == {"p": Decimal(-10)}


def test_three_person_bill_proportional():
    # me paid the whole $30, split three ways ($10 each). A and B each owe me their $10.
    exp = _expense(_split("me", "30", "10"), _split("a", "0", "10"), _split("b", "0", "10"))
    assert compute("me", [exp]) == {"a": Decimal(10), "b": Decimal(10)}


def test_settle_up_nets_pair_toward_zero():
    # I owed P 10 (P paid a $20 even bill), then I settle up by paying P 10.
    bill = _expense(_split("p", "20", "10"), _split("me", "0", "10"))           # me: -10
    settle = _expense(_split("me", "10", "0"), _split("p", "0", "10"))          # me: +10
    assert compute("me", [bill, settle]) == {"p": Decimal(0)}


def test_expense_without_caller_has_no_effect():
    exp = _expense(_split("a", "20", "10"), _split("b", "0", "10"))
    assert compute("me", [exp]) == {}


def test_skips_zero_total_paid():
    exp = _expense(_split("me", "0", "0"), _split("p", "0", "0"))
    assert compute("me", [exp]) == {}


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
