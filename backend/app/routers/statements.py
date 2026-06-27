"""Manual bank-statement (OFX) import — for accounts no aggregator can reach (e.g. Apple Card, which only
offers a monthly Wallet export). The caller uploads the raw OFX bytes; we find-or-create a manual account and
upsert its transactions, de-duped by FITID so re-importing an overlapping statement adds nothing new."""
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import require_auth
from app.db import get_session
from app.integrations.statements import ofx
from app.integrations.statements.institutions import resolve_domain
from app.models import Account, Transaction
from app.models.enums import TransactionSource
from app.schemas.statement import StatementImportResult

router = APIRouter(tags=["statements"])

_OFX_BODY = {
    "content": {"application/x-ofx": {"schema": {"type": "string", "format": "binary"}}},
    "required": True,
}


@router.post("/statements/import", response_model=StatementImportResult, status_code=201,
             openapi_extra={"requestBody": _OFX_BODY})
async def import_statement(
    request: Request,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> StatementImportResult:
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="Empty request body")
    return await import_ofx(session, caller, data)


async def import_ofx(session: AsyncSession, caller: str | None, data: bytes) -> StatementImportResult:
    """Parse an OFX statement and upsert it into a find-or-created manual account. Split from the route so
    it's unit-testable without constructing a `Request`."""
    parsed = ofx.parse(data)
    if not parsed.transactions and not parsed.acctid:
        raise HTTPException(status_code=422, detail="Not a recognizable OFX statement")

    # Find-or-create the manual account this statement belongs to — keyed on the stable OFX account id
    # (ACCTID) when present, else the institution name (older exports without an id).
    name = (parsed.org or "Imported Card").strip()[:255] or "Imported Card"
    if parsed.acctid:
        account = await session.scalar(select(Account).where(
            Account.owner_identifier == caller, Account.external_account_id == parsed.acctid))
    else:
        account = await session.scalar(select(Account).where(
            Account.owner_identifier == caller, Account.name == name, Account.plaid_account_id.is_(None)))
    if account is None:
        account = Account(name=name, type="credit", owner_identifier=caller, currency=parsed.currency,
                          balance=Decimal(0), external_account_id=parsed.acctid)
        session.add(account)
        await session.flush()
    # Refresh institution branding from the statement each import.
    account.name = name
    account.institution_name = parsed.org
    account.institution_domain = resolve_domain(parsed.org)

    # Balances reflect the statement's as-of date — only adopt them when this statement is newer (so importing
    # an older statement later can't regress the balance). LEDGERBAL is negative-when-owed → flip to
    # SplitBack's positive-owed convention; AVAILBAL (available credit) is positive → stored as-is.
    if parsed.ledger_as_of and (account.balance_as_of is None or parsed.ledger_as_of > account.balance_as_of):
        if parsed.ledger_balance is not None:
            account.balance = -parsed.ledger_balance
        if parsed.available_balance is not None:
            account.available_balance = parsed.available_balance
        account.balance_as_of = parsed.ledger_as_of

    # Upsert by FITID: only insert transactions not already present for this account.
    fitids = [t.fitid for t in parsed.transactions]
    existing = set(await session.scalars(select(Transaction.external_transaction_id).where(
        Transaction.account_id == account.id, Transaction.external_transaction_id.in_(fitids))))
    new_txns = [t for t in parsed.transactions if t.fitid not in existing]
    for t in new_txns:
        session.add(Transaction(
            account_id=account.id, external_transaction_id=t.fitid, source=TransactionSource.manual,
            description=t.description, amount=t.amount, currency=parsed.currency, date=t.date,
            owner_identifier=caller))
    await session.commit()

    return StatementImportResult(account_id=account.id, account_name=account.name,
                                 imported=len(new_txns), skipped=len(parsed.transactions) - len(new_txns),
                                 total=len(parsed.transactions))
