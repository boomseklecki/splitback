"""Pure mapping from normalized Splitwise dicts to SplitBack row data.

No DB or network here, so every branch is unit-testable with plain dicts.
"""
from datetime import date, datetime
from decimal import Decimal

NON_GROUP_SENTINEL = "0"
NON_GROUP_NAME = "Non-group expenses"
SETTLEUP_CATEGORY = "Settle-up"


def resolve_user_identifier(user_id: str, first_name: str, user_map: dict[str, str]) -> str:
    mapped = user_map.get(user_id)
    if mapped:
        return mapped
    name = (first_name or "").strip().lower()
    return name or f"swuser_{user_id}"


def expense_group_key(expense: dict) -> str:
    group_id = expense.get("group_id")
    return group_id if group_id else NON_GROUP_SENTINEL


def is_importable(expense: dict) -> bool:
    """Skip deleted expenses; everything else (incl. settle-ups) is imported."""
    return not expense.get("deleted_at")


def _parse_date(value) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value).replace("Z", "+00:00")
    return datetime.fromisoformat(text).date()


def build_group_rows(groups: list[dict], expenses: list[dict]) -> dict[str, str]:
    """Return {splitwise_group_id: name} for every group referenced by an expense."""
    rows = {g["splitwise_id"]: g["name"] for g in groups}
    for expense in expenses:
        if not is_importable(expense):
            continue
        key = expense_group_key(expense)
        if key == NON_GROUP_SENTINEL:
            rows.setdefault(NON_GROUP_SENTINEL, NON_GROUP_NAME)
        elif key not in rows:
            rows[key] = f"Splitwise group {key}"
    return rows


def map_expense(expense: dict, user_map: dict[str, str]) -> dict:
    """Map one Splitwise expense to expense fields + splits. Caller resolves group FK."""
    category = SETTLEUP_CATEGORY if expense.get("payment") else expense.get("category")
    splits = [
        {
            "user_identifier": resolve_user_identifier(
                u["user_id"], u.get("first_name", ""), user_map
            ),
            "paid_share": Decimal(str(u.get("paid_share", "0"))),
            "owed_share": Decimal(str(u.get("owed_share", "0"))),
        }
        for u in expense.get("users", [])
    ]
    return {
        "splitwise_expense_id": expense["splitwise_id"],
        "group_key": expense_group_key(expense),
        "description": expense.get("description", ""),
        "amount": Decimal(str(expense.get("cost", "0"))),
        "currency": expense.get("currency_code", "USD"),
        "date": _parse_date(expense.get("date")),
        "category": category,
        "splits": splits,
    }
