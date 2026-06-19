"""Write a self-hosted expense out to its Splitwise-linked group (two-way sync).

`build_payload` is pure (testable); the orchestration helpers translate a local
Expense + splits into Splitwise calls. Push-first: callers invoke these BEFORE
committing so local state never gets ahead of Splitwise.
"""
import asyncio

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.integrations.splitwise import client as sw_client
from app.models import SplitwiseToken, User


class NoSplitwiseToken(Exception):
    """Raised when no usable Splitwise token is stored for a push."""


def build_payload(expense: dict, splitwise_group_id: str, id_to_swid: dict[str, str]) -> dict:
    """Raises KeyError(identifier) if a participant has no Splitwise user id."""
    users = []
    for split in expense["splits"]:
        identifier = split["user_identifier"]
        swid = id_to_swid.get(identifier)
        if not swid:
            raise KeyError(identifier)
        users.append(
            {
                "user_id": swid,
                "paid_share": str(split["paid_share"]),
                "owed_share": str(split["owed_share"]),
            }
        )
    return {
        "cost": str(expense["amount"]),
        "description": expense["description"],
        "currency_code": expense["currency"],
        "date": expense["date"],
        "group_id": int(splitwise_group_id),
        "users": users,
    }


def _expense_to_dict(expense) -> dict:
    return {
        "amount": expense.amount,
        "description": expense.description,
        "currency": expense.currency,
        "date": expense.date.isoformat(),
        "splits": [
            {
                "user_identifier": s.user_identifier,
                "paid_share": s.paid_share,
                "owed_share": s.owed_share,
            }
            for s in expense.splits
        ],
    }


async def _resolve_swids(session: AsyncSession, identifiers: list[str]) -> dict[str, str]:
    if not identifiers:
        return {}
    rows = await session.scalars(select(User).where(User.identifier.in_(identifiers)))
    return {u.identifier: u.splitwise_user_id for u in rows if u.splitwise_user_id}


async def select_token(session: AsyncSession, expense) -> SplitwiseToken:
    """Prefer the payer's token (split with paid_share > 0); else the single stored
    token. Raises NoSplitwiseToken if none usable."""
    payer_ids = [s.user_identifier for s in expense.splits if s.paid_share and s.paid_share > 0]
    if payer_ids:
        token = await session.scalar(
            select(SplitwiseToken).where(SplitwiseToken.user_identifier.in_(payer_ids))
        )
        if token is not None:
            return token
    tokens = (await session.scalars(select(SplitwiseToken))).all()
    if len(tokens) == 1:
        return tokens[0]
    raise NoSplitwiseToken()


async def _payload_for(session: AsyncSession, expense, group) -> dict:
    id_to_swid = await _resolve_swids(session, [s.user_identifier for s in expense.splits])
    return build_payload(_expense_to_dict(expense), group.splitwise_group_id, id_to_swid)


async def push_create(session: AsyncSession, expense, group, client) -> str:
    payload = await _payload_for(session, expense, group)
    sw_id = await asyncio.to_thread(sw_client.create_expense, client, payload)
    expense.splitwise_expense_id = sw_id
    return sw_id


async def push_update(session: AsyncSession, expense, group, client) -> str:
    payload = await _payload_for(session, expense, group)
    return await asyncio.to_thread(
        sw_client.update_expense, client, expense.splitwise_expense_id, payload
    )


async def push_delete(client, splitwise_expense_id: str) -> None:
    await asyncio.to_thread(sw_client.delete_expense, client, splitwise_expense_id)
