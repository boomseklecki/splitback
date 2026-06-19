"""Thin wrapper over the `splitwise` package that normalizes objects to plain dicts.

Keeping the read layer dict-based decouples the mapper from the package and makes
both independently testable.
"""
from splitwise import Splitwise
from splitwise.expense import Expense as SplitwiseExpense
from splitwise.user import ExpenseUser

from app.config import settings

_PAGE_SIZE = 200


def make_client(access_token: str) -> Splitwise:
    client = Splitwise(settings.splitwise_consumer_key, settings.splitwise_consumer_secret)
    client.setOAuth2AccessToken({"access_token": access_token, "token_type": "bearer"})
    return client


def get_current_user(client: Splitwise) -> dict:
    """The authenticated Splitwise user, normalized for sign-in/find-or-create."""
    user = client.getCurrentUser()
    picture = user.getPicture()
    return {
        "splitwise_id": str(user.getId()),
        "first_name": user.getFirstName() or "",
        "last_name": user.getLastName() or "",
        "email": user.getEmail(),
        "picture": picture.getMedium() if picture else None,
    }


def _normalize_group(group) -> dict:
    members = [
        {
            "user_id": str(m.getId()),
            "first_name": m.getFirstName() or "",
            "last_name": m.getLastName() or "",
            "email": m.getEmail(),
        }
        for m in (group.getMembers() or [])
    ]
    return {"splitwise_id": str(group.getId()), "name": group.getName(), "members": members}


def _normalize_expense(expense) -> dict:
    group_id = expense.getGroupId()
    category = expense.getCategory()
    users = [
        {
            "user_id": str(u.getId()),
            "first_name": u.getFirstName() or "",
            "last_name": u.getLastName() or "",
            "paid_share": u.getPaidShare() or "0",
            "owed_share": u.getOwedShare() or "0",
        }
        for u in expense.getUsers()
    ]
    return {
        "splitwise_id": str(expense.getId()),
        "group_id": None if group_id in (None, 0) else str(group_id),
        "description": expense.getDescription() or "",
        "cost": expense.getCost() or "0",
        "currency_code": expense.getCurrencyCode() or settings.default_currency,
        "date": expense.getDate(),
        "category": category.getName() if category else None,
        "payment": bool(expense.getPayment()),
        "deleted_at": expense.getDeletedAt(),
        "users": users,
    }


def _build_sw_expense(payload: dict, sw_id: str | None = None) -> SplitwiseExpense:
    expense = SplitwiseExpense()
    if sw_id is not None:
        expense.setId(int(sw_id))
    expense.setCost(payload["cost"])
    expense.setDescription(payload["description"])
    expense.setCurrencyCode(payload["currency_code"])
    expense.setDate(payload["date"])
    expense.setGroupId(payload["group_id"])
    for member in payload["users"]:
        user = ExpenseUser()
        user.setId(int(member["user_id"]))
        user.setPaidShare(member["paid_share"])
        user.setOwedShare(member["owed_share"])
        expense.addUser(user)
    return expense


def create_expense(client: Splitwise, payload: dict) -> str:
    """Create an expense in Splitwise from a push payload; returns its id."""
    created, errors = client.createExpense(_build_sw_expense(payload))
    if errors:
        raise RuntimeError(errors.getErrors())
    return str(created.getId())


def update_expense(client: Splitwise, sw_id: str, payload: dict) -> str:
    """Update an existing Splitwise expense; returns its id."""
    updated, errors = client.updateExpense(_build_sw_expense(payload, sw_id=sw_id))
    if errors:
        raise RuntimeError(errors.getErrors())
    return str(updated.getId())


def delete_expense(client: Splitwise, sw_id: str) -> None:
    success, errors = client.deleteExpense(int(sw_id))
    if errors:
        raise RuntimeError(errors.getErrors())


def fetch_groups(client: Splitwise) -> list[dict]:
    return [_normalize_group(g) for g in client.getGroups()]


def fetch_expenses(
    client: Splitwise,
    dated_after: str | None = None,
    dated_before: str | None = None,
) -> list[dict]:
    """Page through all expenses in the user's account within the date window."""
    out: list[dict] = []
    offset = 0
    while True:
        page = client.getExpenses(
            offset=offset,
            limit=_PAGE_SIZE,
            dated_after=dated_after,
            dated_before=dated_before,
        )
        if not page:
            break
        out.extend(_normalize_expense(e) for e in page)
        if len(page) < _PAGE_SIZE:
            break
        offset += _PAGE_SIZE
    return out
