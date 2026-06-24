from datetime import date as date_type
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.auth import require_auth
from app.auth.scope import assert_owner
from app.config import settings
from app.db import get_session
from app.models import Account, AccountOverride, Transaction, TransactionCategoryOverride, TransactionItem
from app.models.enums import TransactionSource
from app.schemas.account import ACCOUNT_KINDS, AccountCreate, AccountResponse, AccountUpdate
from app.schemas.transaction import (
    TransactionCreate,
    TransactionItemInput,
    TransactionResponse,
    TransactionUpdate,
)
from app.utils import ensure_utc

router = APIRouter(tags=["accounts"])


@router.get("/accounts", response_model=list[AccountResponse])
async def list_accounts(
    updated_since: datetime | None = None,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Account]:
    stmt = select(Account)
    if caller is not None:
        stmt = stmt.where(Account.owner_identifier == caller)
    if updated_since is not None:
        stmt = stmt.where(Account.updated_at >= ensure_utc(updated_since))
    rows = list(await session.scalars(stmt.order_by(Account.name)))
    await _attach_account_overrides(session, caller, rows)
    return rows


_OVERRIDE_FIELDS = ("display_name", "kind", "include_in_spending", "include_in_cash_flow")


async def _attach_account_overrides(
    session: AsyncSession, caller: str | None, accounts: list[Account]
) -> None:
    """Populate each account's per-user override fields (display_name/kind/include_*) from the caller's
    `account_overrides` row (none in open mode). The columns moved to `account_overrides`; this sets transient
    attributes the response serializes via `from_attributes`."""
    ids = [a.id for a in accounts]
    by_id: dict = {}
    if caller is not None and ids:
        rows = await session.scalars(
            select(AccountOverride).where(
                AccountOverride.owner_identifier == caller, AccountOverride.account_id.in_(ids)
            )
        )
        by_id = {o.account_id: o for o in rows}
    for a in accounts:
        override = by_id.get(a.id)
        for field in _OVERRIDE_FIELDS:
            setattr(a, field, getattr(override, field) if override is not None else None)


@router.post("/accounts", response_model=AccountResponse, status_code=201)
async def create_account(
    body: AccountCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Account:
    account = Account(
        name=body.name,
        type=body.type,
        balance=body.balance,
        currency=body.currency or settings.default_currency,
        owner_identifier=caller,
    )
    session.add(account)
    await session.commit()
    await session.refresh(account)
    await _attach_account_overrides(session, caller, [account])
    return account


@router.patch("/accounts/{account_id}", response_model=AccountResponse)
async def update_account(
    account_id: UUID,
    body: AccountUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Account:
    """Set the caller's per-user account overrides (display name, kind, Goals-analytics inclusion flags) in
    `account_overrides`, keyed by owner + account. Plaid sync only touches name/type/balance/currency/mask, so
    these survive a re-sync."""
    account = await session.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Account not found")
    assert_owner(account.owner_identifier, caller)
    fields = body.model_dump(exclude_unset=True)
    if "display_name" in fields:
        # Empty/whitespace resets to Plaid's name.
        name = (fields["display_name"] or "").strip()
        fields["display_name"] = name or None
    if fields.get("kind") is not None and fields["kind"] not in ACCOUNT_KINDS:
        raise HTTPException(status_code=422, detail=f"kind must be one of {sorted(ACCOUNT_KINDS)}")
    if caller is not None:  # open mode has no per-user override to key on
        override = await session.scalar(
            select(AccountOverride).where(
                AccountOverride.owner_identifier == caller, AccountOverride.account_id == account_id
            )
        )
        if override is None:
            override = AccountOverride(owner_identifier=caller, account_id=account_id)
            session.add(override)
        for field, value in fields.items():  # only the provided fields (exclude_unset) change
            setattr(override, field, value)
        # Drop the row once every override is cleared.
        if all(getattr(override, field) is None for field in _OVERRIDE_FIELDS):
            await session.delete(override)
        await session.commit()
        await session.refresh(account)  # reload the real columns after commit-expire
    await _attach_account_overrides(session, caller, [account])
    return account


@router.delete("/accounts/{account_id}", status_code=204)
async def delete_account(
    account_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    account = await session.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Account not found")
    assert_owner(account.owner_identifier, caller)
    await session.delete(account)
    await session.commit()


@router.get("/transactions", response_model=list[TransactionResponse])
async def list_transactions(
    account_id: UUID | None = None,
    since: date_type | None = None,
    until: date_type | None = None,
    updated_since: datetime | None = None,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Transaction]:
    stmt = select(Transaction).options(selectinload(Transaction.items))
    if caller is not None:
        stmt = stmt.where(Transaction.owner_identifier == caller)
    if account_id is not None:
        stmt = stmt.where(Transaction.account_id == account_id)
    if since is not None:
        stmt = stmt.where(Transaction.date >= since)
    if until is not None:
        stmt = stmt.where(Transaction.date <= until)
    if updated_since is not None:
        stmt = stmt.where(Transaction.updated_at >= ensure_utc(updated_since))
    stmt = stmt.order_by(Transaction.date.desc(), Transaction.created_at.desc()).limit(limit).offset(offset)
    rows = list(await session.scalars(stmt))
    await _attach_overrides(session, caller, rows)
    return rows


async def _attach_overrides(
    session: AsyncSession, caller: str | None, transactions: list[Transaction]
) -> None:
    """Populate each transaction's `category_override` from the caller's per-user override row (none in open
    mode). The column was moved to `transaction_category_overrides`; this sets a transient attribute the
    response serializes via `from_attributes`."""
    ids = [t.id for t in transactions]
    overrides: dict[UUID, str] = {}
    if caller is not None and ids:
        rows = await session.execute(
            select(TransactionCategoryOverride.transaction_id, TransactionCategoryOverride.category).where(
                TransactionCategoryOverride.owner_identifier == caller,
                TransactionCategoryOverride.transaction_id.in_(ids),
            )
        )
        overrides = {tid: category for tid, category in rows}
    for t in transactions:
        t.category_override = overrides.get(t.id)


async def _load_transaction(
    session: AsyncSession, transaction_id: UUID, caller: str | None = None
) -> Transaction | None:
    """Load a transaction with its items eagerly (async sessions can't lazy-load after the awaited query),
    and attach the caller's category override."""
    stmt = (
        select(Transaction)
        .options(selectinload(Transaction.items))
        .where(Transaction.id == transaction_id)
    )
    transaction = await session.scalar(stmt)
    if transaction is not None:
        await _attach_overrides(session, caller, [transaction])
    return transaction


@router.get("/transactions/{transaction_id}", response_model=TransactionResponse)
async def get_transaction(
    transaction_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Transaction:
    transaction = await _load_transaction(session, transaction_id, caller)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    assert_owner(transaction.owner_identifier, caller)
    return transaction


@router.patch("/transactions/{transaction_id}", response_model=TransactionResponse)
async def update_transaction(
    transaction_id: UUID,
    body: TransactionUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Transaction:
    """Set (or clear, with null) the caller's per-user category override (in `transaction_category_overrides`,
    keyed by owner + transaction). Plaid sync only touches description/amount/currency/date/category/pending,
    so this survives a re-sync."""
    transaction = await session.get(Transaction, transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    assert_owner(transaction.owner_identifier, caller)
    if caller is not None:  # open mode has no per-user override to key on
        row = await session.scalar(
            select(TransactionCategoryOverride).where(
                TransactionCategoryOverride.owner_identifier == caller,
                TransactionCategoryOverride.transaction_id == transaction_id,
            )
        )
        # An omitted field (the generated client drops nil) clears the override → delete the row.
        if body.category_override is None:
            if row is not None:
                await session.delete(row)
        elif row is None:
            session.add(TransactionCategoryOverride(
                owner_identifier=caller, transaction_id=transaction_id, category=body.category_override))
        else:
            row.category = body.category_override
        await session.commit()
    return await _load_transaction(session, transaction_id, caller)


def _apply_transaction_items(
    transaction: Transaction, items: list[TransactionItemInput], editor: str | None
) -> None:
    """Upsert items by id so added-by/added-on survive edits: existing items keep their identity
    (stamping updated_by only when a field changed), new items (id nil) are stamped with created_by,
    and items absent from the payload are dropped (delete-orphan). Mirrors the expense version."""
    existing = {it.id: it for it in transaction.items}
    result: list[TransactionItem] = []
    for i in items:
        current = existing.get(i.id) if i.id is not None else None
        if current is not None:
            changed = (
                current.name != i.name or current.quantity != i.quantity
                or current.price != i.price or current.category != i.category
            )
            current.name = i.name
            current.quantity = i.quantity
            current.price = i.price
            current.category = i.category
            if changed:
                current.updated_by = editor
            result.append(current)
        else:
            result.append(TransactionItem(
                name=i.name, quantity=i.quantity, price=i.price, category=i.category, created_by=editor))
    transaction.items = result


@router.put("/transactions/{transaction_id}/items", response_model=TransactionResponse)
async def set_transaction_items(
    transaction_id: UUID,
    body: list[TransactionItemInput],
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Transaction:
    """Replace a transaction's line items (upsert by id, drop-orphan). A separate endpoint from PATCH so
    it never touches the category-override (whose omitted-clears semantics we must not trip)."""
    transaction = await _load_transaction(session, transaction_id, caller)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    assert_owner(transaction.owner_identifier, caller)
    _apply_transaction_items(transaction, body, editor=None)
    await session.commit()
    return await _load_transaction(session, transaction_id, caller)


@router.post("/transactions", response_model=TransactionResponse, status_code=201)
async def create_transaction(
    body: TransactionCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Transaction:
    transaction = Transaction(
        account_id=body.account_id,
        source=TransactionSource.manual,
        description=body.description,
        amount=body.amount,
        currency=body.currency or settings.default_currency,
        date=body.date,
        category=body.category,
        pending=body.pending,
        owner_identifier=caller,
    )
    session.add(transaction)
    await session.commit()
    return await _load_transaction(session, transaction.id, caller)


@router.delete("/transactions/{transaction_id}", status_code=204)
async def delete_transaction(
    transaction_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    transaction = await session.get(Transaction, transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    assert_owner(transaction.owner_identifier, caller)
    await session.delete(transaction)
    await session.commit()
