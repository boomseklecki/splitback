"""Thin wrapper over the `splitwise` package that normalizes objects to plain dicts.

Keeping the read layer dict-based decouples the mapper from the package and makes
both independently testable.
"""
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

import requests
from splitwise import Splitwise
from splitwise.expense import Expense as SplitwiseExpense
from splitwise.user import ExpenseUser

from app.config import settings

_PAGE_SIZE = 200


def make_client(access_token: str) -> Splitwise:
    client = Splitwise(settings.splitwise_consumer_key, settings.splitwise_consumer_secret)
    client.setOAuth2AccessToken({"access_token": access_token, "token_type": "bearer"})
    return client


def fetch_receipt_bytes(access_token: str, url: str) -> tuple[bytes, str]:
    """Fetch a Splitwise receipt image. The receipt URL is an authenticated API endpoint, so it needs
    the user's OAuth token — it can't be loaded directly by the app. Returns (bytes, content_type)."""
    resp = requests.get(url, headers={"Authorization": f"Bearer {access_token}"}, timeout=30)
    resp.raise_for_status()
    return resp.content, resp.headers.get("content-type") or "image/jpeg"


_RECEIPT_SIZES = {"small", "medium", "large", "original"}


def receipt_url_with_size(url: str, size: str | None) -> str:
    """Rewrite the `size` query param on a Splitwise receipt URL (large/original/…). Unknown sizes
    leave the URL unchanged."""
    if size not in _RECEIPT_SIZES:
        return url
    parts = urlparse(url)
    query = parse_qs(parts.query)
    query["size"] = [size]
    return urlunparse(parts._replace(query=urlencode(query, doseq=True)))


def _method(obj, name: str):
    """Call ``obj.name()`` only when it is a real callable method, else return None.

    The `splitwise` SDK objects define ``__getattr__`` to return None for unknown attributes, so
    ``hasattr(obj, "getWhatever")`` is always True and ``obj.getWhatever()`` raises
    ``TypeError: 'NoneType' object is not callable`` for getters the package doesn't implement.
    Guarding on ``callable()`` is the only safe check.
    """
    fn = getattr(obj, name, None)
    return fn() if callable(fn) else None


def _flag(obj, attr: str, getter: str):
    """A bool-ish flag: prefer the data attribute, fall back to a real getter method."""
    val = getattr(obj, attr, None)
    return val if val is not None else _method(obj, getter)


def _str_or_none(value) -> str | None:
    return str(value) if value is not None else None


def _registration_status(user) -> str | None:
    """Splitwise registration_status ('confirmed' | 'invited' | 'dummy'), when the package exposes it."""
    return _method(user, "getRegistrationStatus") or getattr(user, "registration_status", None)


def _first_url(obj, getters: tuple[str, ...]) -> str | None:
    """First non-empty URL from an image object (avatar/cover/receipt) across the given getters."""
    if obj is None:
        return None
    for getter in getters:
        url = _method(obj, getter)
        if url:
            return url
    return None


def _group_type(group) -> str | None:
    return _method(group, "getGroupType") or getattr(group, "group_type", None)


def _avatar_url(group) -> str | None:
    """Group avatar URL — only a *custom* one (Splitwise serves a generated default otherwise)."""
    if _flag(group, "custom_avatar", "getCustomAvatar") is False:
        return None
    return _first_url(_method(group, "getAvatar"), ("getMedium", "getLarge", "getOriginal"))


def _cover_photo_url(group) -> str | None:
    return _first_url(_method(group, "getCoverPhoto"), ("getXxlarge", "getXlarge", "getOriginal"))


def _receipt_url(expense) -> str | None:
    return _first_url(_method(expense, "getReceipt"), ("getLarge", "getOriginal"))


def _repayments(expense) -> list[dict]:
    """Splitwise's simplified net transfers for an expense: [{from, to, amount}]."""
    out: list[dict] = []
    for r in (_method(expense, "getRepayments") or []):
        out.append({
            "from": _str_or_none(_method(r, "getFromUser")),
            "to": _str_or_none(_method(r, "getToUser")),
            "amount": _method(r, "getAmount"),
        })
    return out


def _user_ref(obj, getter: str) -> dict | None:
    """Extract {user_id, first_name, last_name} from a related Splitwise user (e.g. created_by)."""
    user = _method(obj, getter)
    uid = _method(user, "getId") if user is not None else None
    if uid is None:
        return None
    return {
        "user_id": str(uid),
        "first_name": _method(user, "getFirstName") or "",
        "last_name": _method(user, "getLastName") or "",
    }


def _picture_url(user) -> str | None:
    """The medium avatar URL for a Splitwise user/member — but only a *custom* one.

    Splitwise returns a generic placeholder picture for users who never set one; `custom_picture`
    is False for those, and we'd rather fall back to initials than show the placeholder. When the
    flag isn't available, we keep the picture so we never regress.
    """
    if _flag(user, "custom_picture", "getCustomPicture") is False:
        return None
    return _first_url(_method(user, "getPicture"), ("getMedium", "getLarge", "getOriginal"))


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


def fetch_friends(client: Splitwise) -> list[dict]:
    """The authenticated user's Splitwise friends with their authoritative current balances. Splitwise keeps
    its own friend-level ledger (settle-ups, cross-group netting), so this — not a sum of per-expense
    repayments — is the source of truth for the Friends view. Each balance is per-currency."""
    out: list[dict] = []
    for friend in (client.getFriends() or []):
        out.append({
            "splitwise_id": str(_method(friend, "getId")),
            "first_name": _method(friend, "getFirstName") or "",
            "last_name": _method(friend, "getLastName") or "",
            "email": _method(friend, "getEmail"),
            "picture": _picture_url(friend),
            "balances": [
                {"currency": _method(b, "getCurrencyCode"), "amount": _method(b, "getAmount")}
                for b in (_method(friend, "getBalances") or [])
            ],
            # Per-group breakdown: each entry's balance is the friend's net WITH YOU in that group.
            "groups": [
                {
                    "splitwise_group_id": str(_method(g, "getId")),
                    "balances": [
                        {"currency": _method(b, "getCurrencyCode"), "amount": _method(b, "getAmount")}
                        for b in (_method(g, "getBalances") or [])
                    ],
                }
                for g in (_method(friend, "getGroups") or [])
            ],
        })
    return out


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
            "email": _method(u, "getEmail"),
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
        "created_by": _user_ref(expense, "getCreatedBy"),
        "updated_by": _user_ref(expense, "getUpdatedBy"),
        "created_at": _method(expense, "getCreatedAt"),
        "updated_at": _method(expense, "getUpdatedAt"),
        "notes": _method(expense, "getDetails"),
        "comments_count": _method(expense, "getCommentsCount"),
        "repeats": _method(expense, "getRepeats"),
        "repeat_interval": _method(expense, "getRepeatInterval"),
        "expense_bundle_id": _method(expense, "getExpenseBundleId"),
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
    if payload.get("payment"):
        expense.setPayment(True)
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
    updated_after: str | None = None,
    updated_before: str | None = None,
    group_id: str | None = None,
) -> list[dict]:
    """Page through the user's expenses. `dated_*` windows by expense date (backfill);
    `updated_after` returns only rows changed since a cursor (incremental sync) and includes
    deleted ones. `group_id` scopes to one group (drill-in)."""
    out: list[dict] = []
    offset = 0
    while True:
        page = client.getExpenses(
            offset=offset,
            limit=_PAGE_SIZE,
            group_id=group_id,
            dated_after=dated_after,
            dated_before=dated_before,
            updated_after=updated_after,
            updated_before=updated_before,
        )
        if not page:
            break
        out.extend(_normalize_expense(e) for e in page)
        if len(page) < _PAGE_SIZE:
            break
        offset += _PAGE_SIZE
    return out
