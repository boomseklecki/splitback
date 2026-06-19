import asyncio
from datetime import date as date_type
from datetime import datetime, timezone
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import settings
from app.db import get_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import writer as sw_writer
from app.integrations.storage import minio_client
from app.models import BackendType, Expense, ExpenseItem, Group, Split
from app.schemas.expense import ExpenseCreate, ExpenseResponse, ExpenseUpdate
from app.utils import ensure_utc

router = APIRouter(tags=["expenses"])

_TOLERANCE = Decimal("0.01")


async def _sync_to_splitwise(session, expense, group, op: str, sw_id: str | None = None) -> str | None:
    """Push a create/update/delete to the expense's Splitwise group (push-first).
    Maps failures: no token -> 409, missing Splitwise user id -> 422, upstream -> 502."""
    if not group.splitwise_group_id:
        raise HTTPException(status_code=400, detail="Splitwise group is missing splitwise_group_id")
    try:
        token = await sw_writer.select_token(session, expense)
    except sw_writer.NoSplitwiseToken:
        raise HTTPException(
            status_code=409,
            detail="No Splitwise token stored; authorize via /auth/splitwise/login first",
        )
    client = sw_client.make_client(token.access_token)
    try:
        if op == "create":
            return await sw_writer.push_create(session, expense, group, client)
        if op == "update":
            return await sw_writer.push_update(session, expense, group, client)
        await sw_writer.push_delete(client, sw_id)
        return None
    except KeyError as exc:
        raise HTTPException(
            status_code=422, detail=f"No Splitwise user id for participant '{exc.args[0]}'"
        )
    except Exception as exc:  # SDK / upstream Splitwise error
        raise HTTPException(status_code=502, detail=f"Splitwise rejected the request: {exc}")


def _validate_splits(amount: Decimal, splits) -> None:
    """Splits must balance against the amount within a cent. Duck-typed on
    .paid_share / .owed_share so both SplitInput and Split ORM rows work."""
    if not splits:
        return
    paid = sum((s.paid_share for s in splits), Decimal(0))
    owed = sum((s.owed_share for s in splits), Decimal(0))
    if abs(paid - amount) > _TOLERANCE or abs(owed - amount) > _TOLERANCE:
        raise HTTPException(
            status_code=422,
            detail=f"Splits must balance: paid_share sum={paid}, owed_share sum={owed}, amount={amount}",
        )


def _split_rows(splits) -> list[Split]:
    return [
        Split(
            user_identifier=s.user_identifier,
            paid_share=s.paid_share,
            owed_share=s.owed_share,
        )
        for s in splits
    ]


def _item_rows(items) -> list[ExpenseItem]:
    return [
        ExpenseItem(name=i.name, quantity=i.quantity, price=i.price, category=i.category)
        for i in items
    ]


async def _load_detail(session: AsyncSession, expense_id: UUID) -> Expense | None:
    stmt = (
        select(Expense)
        .where(Expense.id == expense_id)
        .options(
            selectinload(Expense.splits),
            selectinload(Expense.items),
            selectinload(Expense.receipts),
        )
    )
    return await session.scalar(stmt)


async def _get_group_or_404(session: AsyncSession, group_id: UUID) -> Group:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    return group


@router.post("/expenses", response_model=ExpenseResponse, status_code=201)
async def create_expense(
    body: ExpenseCreate, session: AsyncSession = Depends(get_session)
) -> Expense:
    group = await _get_group_or_404(session, body.group_id)
    if group.backend_type == BackendType.self_hosted:
        _validate_splits(body.amount, body.splits)

    expense = Expense(
        group_id=body.group_id,
        transaction_id=body.transaction_id,
        description=body.description,
        amount=body.amount,
        currency=body.currency or settings.default_currency,
        date=body.date,
        category=body.category,
        notes=body.notes,
        created_by=body.created_by,
    )
    expense.splits = _split_rows(body.splits)
    expense.items = _item_rows(body.items)
    if group.backend_type == BackendType.splitwise:
        # Push-first: create on Splitwise and stamp the returned id before committing.
        await _sync_to_splitwise(session, expense, group, "create")
    session.add(expense)
    await session.commit()
    return await _load_detail(session, expense.id)


@router.get("/expenses", response_model=list[ExpenseResponse])
async def list_expenses(
    group_id: UUID | None = None,
    since: date_type | None = None,
    until: date_type | None = None,
    updated_since: datetime | None = None,
    include_archived: bool = False,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    session: AsyncSession = Depends(get_session),
) -> list[Expense]:
    stmt = select(Expense).options(
        selectinload(Expense.splits),
        selectinload(Expense.items),
        selectinload(Expense.receipts),
    )
    if not include_archived:
        stmt = stmt.join(Group, Expense.group_id == Group.id).where(
            Group.archived_at.is_(None), Expense.archived_at.is_(None)
        )
    if group_id is not None:
        stmt = stmt.where(Expense.group_id == group_id)
    if since is not None:
        stmt = stmt.where(Expense.date >= since)
    if until is not None:
        stmt = stmt.where(Expense.date <= until)
    if updated_since is not None:
        stmt = stmt.where(Expense.updated_at >= ensure_utc(updated_since))
    stmt = stmt.order_by(Expense.date.desc(), Expense.created_at.desc()).limit(limit).offset(offset)
    rows = await session.scalars(stmt)
    return list(rows)


@router.get("/expenses/{expense_id}", response_model=ExpenseResponse)
async def get_expense(
    expense_id: UUID, session: AsyncSession = Depends(get_session)
) -> Expense:
    expense = await _load_detail(session, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    return expense


@router.patch("/expenses/{expense_id}", response_model=ExpenseResponse)
async def update_expense(
    expense_id: UUID, body: ExpenseUpdate, session: AsyncSession = Depends(get_session)
) -> Expense:
    expense = await _load_detail(session, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")

    target_group = await _get_group_or_404(session, body.group_id or expense.group_id)
    new_amount = body.amount if body.amount is not None else expense.amount
    if target_group.backend_type == BackendType.self_hosted:
        splits_to_check = body.splits if body.splits is not None else expense.splits
        _validate_splits(new_amount, splits_to_check)

    if body.group_id is not None:
        expense.group_id = body.group_id
    if body.description is not None:
        expense.description = body.description
    if body.amount is not None:
        expense.amount = body.amount
    if body.currency is not None:
        expense.currency = body.currency
    if body.date is not None:
        expense.date = body.date
    if body.category is not None:
        expense.category = body.category
    if body.notes is not None:
        expense.notes = body.notes
    if body.updated_by is not None:
        expense.updated_by = body.updated_by
    if body.transaction_id is not None:
        expense.transaction_id = body.transaction_id
    if body.splits is not None:
        expense.splits = _split_rows(body.splits)
    if body.items is not None:
        expense.items = _item_rows(body.items)

    if target_group.backend_type == BackendType.splitwise:
        # Push the edit; heal a pre-existing phantom (no id yet) by creating instead.
        if expense.splitwise_expense_id:
            await _sync_to_splitwise(session, expense, target_group, "update")
        else:
            await _sync_to_splitwise(session, expense, target_group, "create")

    await session.commit()
    return await _load_detail(session, expense_id)


async def _archive(session: AsyncSession, expense: Expense) -> None:
    expense.archived_at = datetime.now(timezone.utc)
    await session.commit()


async def _hard_delete(session: AsyncSession, expense: Expense) -> None:
    for receipt in expense.receipts:
        try:
            await asyncio.to_thread(minio_client.remove, receipt.object_key)
        except Exception:
            pass  # best-effort storage cleanup
    await session.delete(expense)
    await session.commit()


@router.delete("/expenses/{expense_id}", status_code=204)
async def delete_expense(
    expense_id: UUID,
    propagate: bool | None = None,
    session: AsyncSession = Depends(get_session),
) -> None:
    expense = await _load_detail(session, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")

    # Local-only expense: SplitBack owns the ledger -> archive (or hard-delete if enabled).
    if expense.splitwise_expense_id is None:
        if settings.expenses_hard_delete_enabled:
            await _hard_delete(session, expense)
        else:
            await _archive(session, expense)
        return

    # Splitwise-linked. Default: propagate for an ACTIVE group (keep balances in parity),
    # archive locally for an ARCHIVED group (it's retired; leave the friends' data alone).
    # `propagate` overrides either way.
    group = await session.get(Group, expense.group_id)
    do_propagate = propagate if propagate is not None else (group.archived_at is None)
    if not do_propagate:
        await _archive(session, expense)
        return

    if group.backend_type == BackendType.splitwise:
        await _sync_to_splitwise(
            session, expense, group, "delete", sw_id=expense.splitwise_expense_id
        )
    await _hard_delete(session, expense)
