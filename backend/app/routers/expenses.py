import asyncio
from datetime import date as date_type
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.auth import require_auth
from app.auth.scope import assert_group_member
from app.config import settings
from app.db import get_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import writer as sw_writer
from app.integrations.splitwise.mapper import SETTLEUP_CATEGORY
from app.integrations.storage import minio_client
from app.models import (
    BackendType, Expense, ExpenseItem, ExpenseOverride, Group, GroupMember, Split, Transaction,
)
from app.services import notify as notify_svc
from app.schemas.expense import (
    ExpenseCreate,
    ExpenseOverrideUpdate,
    ExpenseResponse,
    ExpenseTransactionLink,
    ExpenseUpdate,
)
from app.utils import ensure_utc

router = APIRouter(tags=["expenses"])

_TOLERANCE = Decimal("0.01")


async def _sync_to_splitwise(session, expense, group, op: str, sw_id: str | None = None,
                             caller: str | None = None) -> str | None:
    """Push a create/update/delete to the expense's Splitwise group (push-first).
    Maps failures: no token -> 409, missing Splitwise user id -> 422, upstream -> 502."""
    if not group.splitwise_group_id:
        raise HTTPException(status_code=400, detail="Splitwise group is missing splitwise_group_id")
    try:
        token = await sw_writer.select_token(session, expense, caller)
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


def _item_rows(items, created_by: str | None = None) -> list[ExpenseItem]:
    return [
        ExpenseItem(name=i.name, quantity=i.quantity, price=i.price, category=i.category,
                    owner_identifier=i.owner_identifier, created_by=created_by)
        for i in items
    ]


def _apply_items(expense: Expense, items, editor: str | None) -> None:
    """Upsert items by id so added-by/added-on survive edits: existing items keep their identity
    (stamping updated_by only when a field changed), new items (id nil) are stamped with created_by,
    and items absent from the payload are dropped (delete-orphan)."""
    existing = {it.id: it for it in expense.items}
    result: list[ExpenseItem] = []
    for i in items:
        current = existing.get(i.id) if i.id is not None else None
        if current is not None:
            changed = (
                current.name != i.name or current.quantity != i.quantity
                or current.price != i.price or current.category != i.category
                or current.owner_identifier != i.owner_identifier
            )
            current.name = i.name
            current.quantity = i.quantity
            current.price = i.price
            current.category = i.category
            current.owner_identifier = i.owner_identifier
            if changed:
                current.updated_by = editor
            result.append(current)
        else:
            result.append(_item_rows([i], created_by=editor)[0])
    expense.items = result


_EXPENSE_OVERRIDE_FIELDS = ("include_in_spending", "include_in_cash_flow")


async def _attach_expense_overrides(
    session: AsyncSession, caller: str | None, expenses: list[Expense]
) -> None:
    """Populate each expense's per-user budget flags from the caller's `expense_overrides` row (none in open
    mode); sets transient attributes the response serializes via `from_attributes`."""
    ids = [e.id for e in expenses]
    by_id: dict[UUID, ExpenseOverride] = {}
    if caller is not None and ids:
        rows = await session.scalars(
            select(ExpenseOverride).where(
                ExpenseOverride.owner_identifier == caller, ExpenseOverride.expense_id.in_(ids)
            )
        )
        by_id = {o.expense_id: o for o in rows}
    for e in expenses:
        o = by_id.get(e.id)
        for field in _EXPENSE_OVERRIDE_FIELDS:
            setattr(e, field, getattr(o, field) if o is not None else None)


async def _load_detail(
    session: AsyncSession, expense_id: UUID, caller: str | None = None
) -> Expense | None:
    stmt = (
        select(Expense)
        .where(Expense.id == expense_id)
        .options(
            selectinload(Expense.splits),
            selectinload(Expense.items),
            selectinload(Expense.receipts),
        )
    )
    expense = await session.scalar(stmt)
    if expense is not None:
        await _attach_expense_overrides(session, caller, [expense])
    return expense


async def _get_group_or_404(session: AsyncSession, group_id: UUID) -> Group:
    group = await session.get(Group, group_id)
    if group is None:
        raise HTTPException(status_code=404, detail="Group not found")
    return group


@router.post("/expenses", response_model=ExpenseResponse, status_code=201)
async def create_expense(
    body: ExpenseCreate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Expense:
    group = await _get_group_or_404(session, body.group_id)
    await assert_group_member(session, body.group_id, caller)
    # A since-posted (deleted) pending transaction → clean 404, not an FK 500 on commit (the app keys its
    # "already posted" prompt off this). Matches link_expense_transaction.
    if body.transaction_id is not None and await session.get(Transaction, body.transaction_id) is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
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
    expense.items = _item_rows(body.items, created_by=body.created_by)
    if group.backend_type == BackendType.splitwise:
        # Push-first: create on Splitwise and stamp the returned id before committing.
        await _sync_to_splitwise(session, expense, group, "create", caller=caller)
    session.add(expense)
    await session.commit()
    # Notify the other members of a local group (Splitwise groups get Splitwise's own notifications).
    if group.backend_type == BackendType.self_hosted:
        actor = await notify_svc.display_name(session, caller)
        settle = body.category == SETTLEUP_CATEGORY
        await notify_svc.notify(
            session, await notify_svc.group_recipients(session, body.group_id),
            "settle_up" if settle else "expense_added",
            f"{actor} recorded a settle-up" if settle else f"{actor} added “{body.description}”",
            actor=caller)
    return await _load_detail(session, expense.id, caller)


@router.get("/expenses", response_model=list[ExpenseResponse])
async def list_expenses(
    group_id: UUID | None = None,
    since: date_type | None = None,
    until: date_type | None = None,
    updated_since: datetime | None = None,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> list[Expense]:
    stmt = select(Expense).options(
        selectinload(Expense.splits),
        selectinload(Expense.items),
        selectinload(Expense.receipts),
    )
    if caller is not None:  # only expenses in groups the caller belongs to
        stmt = stmt.where(
            Expense.group_id.in_(
                select(GroupMember.group_id).where(GroupMember.user_identifier == caller)
            )
        )
    # Exclude expenses of a group that's been superseded by a local import (its expenses live on the clone).
    stmt = stmt.join(Group, Expense.group_id == Group.id).where(Group.superseded_at.is_(None))
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
    expenses = list(rows)
    await _attach_expense_overrides(session, caller, expenses)
    return expenses


@router.get("/expenses/{expense_id}", response_model=ExpenseResponse)
async def get_expense(
    expense_id: UUID,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Expense:
    expense = await _load_detail(session, expense_id, caller)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)
    return expense


@router.patch("/expenses/{expense_id}", response_model=ExpenseResponse)
async def update_expense(
    expense_id: UUID,
    body: ExpenseUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Expense:
    expense = await _load_detail(session, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)

    target_group = await _get_group_or_404(session, body.group_id or expense.group_id)
    if body.group_id is not None:  # moving the expense — the caller must also be in the destination
        await assert_group_member(session, body.group_id, caller)
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
        _apply_items(expense, body.items, body.updated_by)

    if target_group.backend_type == BackendType.splitwise:
        # Push the edit; heal a pre-existing phantom (no id yet) by creating instead.
        if expense.splitwise_expense_id:
            await _sync_to_splitwise(session, expense, target_group, "update", caller=caller)
        else:
            await _sync_to_splitwise(session, expense, target_group, "create", caller=caller)

    await session.commit()
    if target_group.backend_type == BackendType.self_hosted:
        actor = await notify_svc.display_name(session, caller)
        await notify_svc.notify(
            session, await notify_svc.group_recipients(session, expense.group_id),
            "expense_edited", f"{actor} edited “{expense.description}”", actor=caller)
    return await _load_detail(session, expense_id, caller)


@router.put("/expenses/{expense_id}/transaction-link", response_model=ExpenseResponse)
async def link_expense_transaction(
    expense_id: UUID,
    body: ExpenseTransactionLink,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Expense:
    """Link (or unlink, with null) this expense to a bank/manual transaction. A local-only field assigned
    directly — a separate endpoint from PATCH so it never triggers a Splitwise push or touches splits, and
    so null can clear the link (PATCH's transaction_id can only set)."""
    expense = await session.get(Expense, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)
    # Validate the target transaction exists so linking a since-posted (deleted) pending row 404s cleanly
    # instead of failing the FK on commit — the app keys its "already posted" prompt off this 404.
    if body.transaction_id is not None and await session.get(Transaction, body.transaction_id) is None:
        raise HTTPException(status_code=404, detail="Transaction not found")
    expense.transaction_id = body.transaction_id
    await session.commit()
    return await _load_detail(session, expense_id, caller)


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
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> None:
    """Permanently delete the expense (hard delete + receipt cleanup). For a Splitwise-linked expense in an
    active group it also deletes it on Splitwise (so balances stay in parity); `propagate=false` keeps the
    Splitwise copy. To exclude an expense from your budget without deleting it, use the per-user override."""
    expense = await _load_detail(session, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)
    group = await session.get(Group, expense.group_id)
    # Capture before the row is gone (local groups only — Splitwise has its own notifications).
    local_recipients = (await notify_svc.group_recipients(session, expense.group_id)
                        if group is not None and group.backend_type == BackendType.self_hosted else set())
    description = expense.description

    if expense.splitwise_expense_id is not None:
        do_propagate = propagate if propagate is not None else (group.superseded_at is None)
        if do_propagate and group.backend_type == BackendType.splitwise:
            await _sync_to_splitwise(
                session, expense, group, "delete", sw_id=expense.splitwise_expense_id, caller=caller
            )
    await _hard_delete(session, expense)
    if local_recipients:
        actor = await notify_svc.display_name(session, caller)
        await notify_svc.notify(session, local_recipients, "expense_deleted",
                                f"{actor} deleted “{description}”", actor=caller)


@router.patch("/expenses/{expense_id}/override", response_model=ExpenseResponse)
async def update_expense_override(
    expense_id: UUID,
    body: ExpenseOverrideUpdate,
    caller: str | None = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
) -> Expense:
    """Set the caller's per-user budget overrides (include in spending / cash flow) in `expense_overrides`,
    keyed by owner + expense. Only provided fields change (exclude_unset); null clears that field, and the row
    is dropped once every field is null. Never propagates to Splitwise and never touches balances."""
    expense = await _load_detail(session, expense_id, caller)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    await assert_group_member(session, expense.group_id, caller)
    if caller is not None:  # open mode has no per-user override to key on
        fields = body.model_dump(exclude_unset=True)
        override = await session.scalar(
            select(ExpenseOverride).where(
                ExpenseOverride.owner_identifier == caller, ExpenseOverride.expense_id == expense_id
            )
        )
        if override is None:
            override = ExpenseOverride(owner_identifier=caller, expense_id=expense_id)
            session.add(override)
        for field, value in fields.items():
            setattr(override, field, value)
        if all(getattr(override, field) is None for field in _EXPENSE_OVERRIDE_FIELDS):
            await session.delete(override)
        await session.commit()
    return await _load_detail(session, expense_id, caller)
