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


def _registration_status(user) -> str | None:
    """Splitwise registration_status ('confirmed' | 'invited' | 'dummy'), when the package exposes it."""
    if hasattr(user, "getRegistrationStatus"):
        return user.getRegistrationStatus()
    return getattr(user, "registration_status", None)


def _first_url(obj, getters: tuple[str, ...]) -> str | None:
    """First non-empty URL from an image object (avatar/cover/receipt) across the given getters."""
    if obj is None:
        return None
    for getter in getters:
        if hasattr(obj, getter):
            url = getattr(obj, getter)()
            if url:
                return url
    return None


def _group_type(group) -> str | None:
    if hasattr(group, "getGroupType"):
        return group.getGroupType()
    return getattr(group, "group_type", None)


def _avatar_url(group) -> str | None:
    """Group avatar URL — only a *custom* one (Splitwise serves a generated default otherwise)."""
    custom = group.getCustomAvatar() if hasattr(group, "getCustomAvatar") else getattr(group, "custom_avatar", None)
    if custom is False:
        return None
    avatar = group.getAvatar() if hasattr(group, "getAvatar") else None
    return _first_url(avatar, ("getMedium", "getLarge", "getOriginal"))


def _cover_photo_url(group) -> str | None:
    cover = group.getCoverPhoto() if hasattr(group, "getCoverPhoto") else None
    return _first_url(cover, ("getXxlarge", "getXlarge", "getOriginal"))


def _receipt_url(expense) -> str | None:
    receipt = expense.getReceipt() if hasattr(expense, "getReceipt") else None
    return _first_url(receipt, ("getLarge", "getOriginal"))


def _repayments(expense) -> list[dict]:
    """Splitwise's simplified net transfers for an expense: [{from, to, amount}]."""
    repayments = expense.getRepayments() if hasattr(expense, "getRepayments") else None
    out: list[dict] = []
    for r in (repayments or []):
        out.append({
            "from": str(r.getFromUser()) if hasattr(r, "getFromUser") and r.getFromUser() is not None else None,
            "to": str(r.getToUser()) if hasattr(r, "getToUser") and r.getToUser() is not None else None,
            "amount": r.getAmount() if hasattr(r, "getAmount") else None,
        })
    return out


def _picture_url(user) -> str | None:
    """The medium avatar URL for a Splitwise user/member — but only a *custom* one.

    Splitwise returns a generic placeholder picture for users who never set one; `custom_picture`
    is False for those, and we'd rather fall back to initials than show the placeholder. When the
    flag isn't available (older package), we keep the picture so we never regress.
    """
    custom = getattr(user, "custom_picture", None)
    if custom is None and hasattr(user, "getCustomPicture"):
        custom = user.getCustomPicture()
    if custom is False:
        return None
    picture = user.getPicture() if hasattr(user, "getPicture") else None
    return picture.getMedium() if picture else None


def get_current_user(client: Splitwise) -> dict:
    """The authenticated Splitwise user, normalized for sign-in/find-or-create."""
    user = client.getCurrentUser()
    return {
        "splitwise_id": str(user.getId()),
        "first_name": user.getFirstName() or "",
        "last_name": user.getLastName() or "",
        "email": user.getEmail(),
        "picture": _picture_url(user),
    }


def _normalize_group(group) -> dict:
    members = [
        {
            "user_id": str(m.getId()),
            "first_name": m.getFirstName() or "",
            "last_name": m.getLastName() or "",
            "email": m.getEmail(),
            "picture": _picture_url(m),
            "registration_status": _registration_status(m),
        }
        for m in (group.getMembers() or [])
    ]
    return {
        "splitwise_id": str(group.getId()),
        "name": group.getName(),
        "group_type": _group_type(group),
        "avatar_url": _avatar_url(group),
        "cover_photo_url": _cover_photo_url(group),
        "members": members,
    }


def _normalize_expense(expense) -> dict:
    group_id = expense.getGroupId()
    category = expense.getCategory()
    users = [
        {
            "user_id": str(u.getId()),
            "first_name": u.getFirstName() or "",
            "last_name": u.getLastName() or "",
            "email": u.getEmail() if hasattr(u, "getEmail") else None,
            "picture": _picture_url(u),
            "registration_status": _registration_status(u),
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
        "receipt_url": _receipt_url(expense),
        "repayments": _repayments(expense),
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
