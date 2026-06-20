from datetime import date as date_type
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_session
from app.models import Account, Transaction
from app.models.enums import TransactionSource
from app.schemas.account import AccountCreate, AccountResponse, AccountUpdate
from app.schemas.transaction import TransactionCreate, TransactionResponse
from app.utils import ensure_utc

router = APIRouter(tags=["accounts"])


@router.get("/accounts", response_model=list[AccountResponse])
async def list_accounts(
    updated_since: datetime | None = None, session: AsyncSession = Depends(get_session)
) -> list[Account]:
    stmt = select(Account)
    if updated_since is not None:
        stmt = stmt.where(Account.updated_at >= ensure_utc(updated_since))
    rows = await session.scalars(stmt.order_by(Account.name))
    return list(rows)


@router.post("/accounts", response_model=AccountResponse, status_code=201)
async def create_account(
    body: AccountCreate, session: AsyncSession = Depends(get_session)
) -> Account:
    account = Account(
        name=body.name,
        type=body.type,
        balance=body.balance,
        currency=body.currency or settings.default_currency,
    )
    session.add(account)
    await session.commit()
    await session.refresh(account)
    return account


@router.patch("/accounts/{account_id}", response_model=AccountResponse)
async def update_account(
    account_id: UUID, body: AccountUpdate, session: AsyncSession = Depends(get_session)
) -> Account:
    """Set the Goals-analytics inclusion overrides. Plaid sync only touches name/type/balance/
    currency, so these survive a re-sync."""
    account = await session.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Account not found")
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(account, field, value)
    await session.commit()
    await session.refresh(account)
    return account


@router.delete("/accounts/{account_id}", status_code=204)
async def delete_account(
    account_id: UUID, session: AsyncSession = Depends(get_session)
) -> None:
    account = await session.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Account not found")
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
    session: AsyncSession = Depends(get_session),
) -> list[Transaction]:
    stmt = select(Transaction)
    if account_id is not None:
        stmt = stmt.where(Transaction.account_id == account_id)
    if since is not None:
        stmt = stmt.where(Transaction.date >= since)
    if until is not None:
        stmt = stmt.where(Transaction.date <= until)
    if updated_since is not None:
        stmt = stmt.where(Transaction.updated_at >= ensure_utc(updated_since))
    stmt = stmt.order_by(Transaction.date.desc(), Transaction.created_at.desc()).limit(limit).offset(offset)
    rows = await session.scalars(stmt)
    return list(rows)


@router.get("/transactions/{transaction_id}", response_model=TransactionResponse)
async def get_transaction(
    transaction_id: UUID, session: AsyncSession = Depends(get_session)
) -> Transaction:
    transaction = await session.get(Transaction, transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    return transaction


@router.post("/transactions", response_model=TransactionResponse, status_code=201)
async def create_transaction(
    body: TransactionCreate, session: AsyncSession = Depends(get_session)
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
    )
    session.add(transaction)
    await session.commit()
    await session.refresh(transaction)
    return transaction


@router.delete("/transactions/{transaction_id}", status_code=204)
async def delete_transaction(
    transaction_id: UUID, session: AsyncSession = Depends(get_session)
) -> None:
    transaction = await session.get(Transaction, transaction_id)
    if transaction is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    await session.delete(transaction)
    await session.commit()
