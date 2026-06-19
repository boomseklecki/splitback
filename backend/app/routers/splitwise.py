import asyncio
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import settings
from app.db import get_session
from app.integrations.splitwise import client as sw_client
from app.integrations.splitwise import importer
from app.integrations.splitwise import receipts as sw_receipts
from app.integrations.storage import minio_client
from app.models import BackendType, Expense, ExpenseItem, Group, GroupMember, Receipt, Split, SplitwiseToken
from app.schemas.group import GroupResponse
from app.schemas.splitwise import (
    LocalImportRequest,
    LocalImportResult,
    ReceiptDownloadResult,
    SplitwiseImportRequest,
    SplitwiseImportResult,
    SplitwiseStatus,
    SyncRequest,
    SyncResult,
)

router = APIRouter(prefix="/splitwise", tags=["splitwise"])


@router.get("/status", response_model=SplitwiseStatus)
async def status(session: AsyncSession = Depends(get_session)) -> SplitwiseStatus:
    users = (await session.scalars(select(SplitwiseToken.user_identifier))).all()
    return SplitwiseStatus(connected=len(users) > 0, users=list(users))


async def _select_token(session: AsyncSession, as_user: str | None) -> SplitwiseToken:
    query = select(SplitwiseToken)
    if as_user:
        query = query.where(SplitwiseToken.user_identifier == as_user)
    tokens = (await session.scalars(query)).all()
    if not tokens:
        raise HTTPException(
            status_code=400, detail="No Splitwise token; authorize via /auth/splitwise/login first"
        )
    if len(tokens) > 1 and not as_user:
        raise HTTPException(status_code=400, detail="Multiple tokens stored; specify as_user")
    return tokens[0]


@router.get("/expenses/{expense_id}/receipt")
async def splitwise_receipt(
    expense_id: UUID, size: str | None = None, session: AsyncSession = Depends(get_session)
) -> Response:
    """Proxy a Splitwise expense's receipt image. Splitwise serves receipts from an authenticated API
    endpoint, so we fetch with the stored OAuth token and stream the bytes back to the app. `size`
    (e.g. `original`) requests a higher resolution for the full-screen view."""
    expense = await session.get(Expense, expense_id)
    if expense is None or not expense.splitwise_receipt_url:
        raise HTTPException(status_code=404, detail="No Splitwise receipt for this expense")
    token = (await session.scalars(select(SplitwiseToken))).first()
    if token is None:
        raise HTTPException(status_code=400, detail="No Splitwise token")
    url = sw_client.receipt_url_with_size(expense.splitwise_receipt_url, size)
    try:
        content, content_type = await asyncio.to_thread(
            sw_client.fetch_receipt_bytes, token.access_token, url
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail="Failed to fetch Splitwise receipt") from exc
    return Response(
        content=content,
        media_type=content_type,
        headers={"Cache-Control": "private, max-age=86400"},
    )


@router.post("/import", response_model=SplitwiseImportResult)
async def run_import(
    body: SplitwiseImportRequest, session: AsyncSession = Depends(get_session)
) -> dict:
    """Cold backfill (full window). Stamps the incremental cursor so /sync/expenses takes over."""
    token = await _select_token(session, body.as_user)
    started = datetime.now(timezone.utc)
    result = await importer.run_import(
        session,
        access_token=token.access_token,
        dated_after=body.since,
        dated_before=body.until,
        user_map=settings.splitwise_user_map,
        dry_run=body.dry_run,
    )
    if not body.dry_run:
        token.expenses_synced_at = started
        await session.commit()
    return result


@router.post("/sync/groups", response_model=SyncResult)
async def sync_groups(
    body: SyncRequest, session: AsyncSession = Depends(get_session)
) -> SyncResult:
    """Pull-to-refresh the Groups list: refresh group metadata + members."""
    token = await _select_token(session, body.as_user)
    client = sw_client.make_client(token.access_token)
    stats = await importer.sync_groups(session, client, settings.splitwise_user_map)
    return SyncResult(**stats)


@router.post("/sync/users", response_model=SyncResult)
async def sync_users(
    body: SyncRequest, session: AsyncSession = Depends(get_session)
) -> SyncResult:
    """Pull-to-refresh the People list: refresh the users directory (members + current user)."""
    token = await _select_token(session, body.as_user)
    client = sw_client.make_client(token.access_token)
    stats = await importer.sync_users(session, client, settings.splitwise_user_map)
    return SyncResult(**stats)


@router.post("/sync/expenses", response_model=SyncResult)
async def sync_expenses(
    body: SyncRequest, session: AsyncSession = Depends(get_session)
) -> SyncResult:
    """Pull-to-refresh expenses: incremental pull since the stored cursor (or `since` override).
    Catches edits/settle-ups and archives expenses Splitwise has deleted."""
    token = await _select_token(session, body.as_user)
    client = sw_client.make_client(token.access_token)
    updated_after = body.since or (
        token.expenses_synced_at.isoformat() if token.expenses_synced_at else None
    )
    started = datetime.now(timezone.utc)
    stats = await importer.sync_expenses(
        session, client, settings.splitwise_user_map,
        updated_after=updated_after, dry_run=body.dry_run,
    )
    if not body.dry_run:
        token.expenses_synced_at = started
        await session.commit()
    return SyncResult(**stats, dry_run=body.dry_run, cursor=None if body.dry_run else started)


async def _copy_uploaded_receipt(session: AsyncSession, source: Receipt, target_expense_id: UUID) -> None:
    """Duplicate an app-uploaded receipt's MinIO object onto a cloned expense (independent copy)."""
    data = await asyncio.to_thread(minio_client.get_bytes, source.object_key)
    object_key = minio_client.build_object_key(target_expense_id, source.content_type)
    await asyncio.to_thread(minio_client.put_object, object_key, data, source.content_type)
    session.add(Receipt(
        expense_id=target_expense_id, bucket=settings.minio_bucket,
        object_key=object_key, content_type=source.content_type,
    ))


@router.post("/groups/{group_id}/import-local", response_model=LocalImportResult)
async def import_group_local(
    group_id: UUID, body: LocalImportRequest, session: AsyncSession = Depends(get_session)
) -> LocalImportResult:
    """Clone a Splitwise-linked group into a new self-hosted group (native, full-featured copies of
    expenses incl. provenance, splits, items, and receipts), then archive the source so balances don't
    double-count. With SPLITWISE_RECEIPT_DOWNLOAD_ENABLED, each Splitwise receipt's original image is
    downloaded into MinIO so the local copy is self-contained."""
    source = await session.get(Group, group_id)
    if source is None:
        raise HTTPException(status_code=404, detail="Group not found")
    if source.backend_type != BackendType.splitwise:
        raise HTTPException(status_code=400, detail="Source must be a Splitwise-linked group")

    expenses = (
        await session.scalars(
            select(Expense)
            .where(Expense.group_id == source.id, Expense.archived_at.is_(None))
            .options(
                selectinload(Expense.splits),
                selectinload(Expense.items),
                selectinload(Expense.receipts),
            )
        )
    ).all()
    members = (
        await session.scalars(select(GroupMember).where(GroupMember.group_id == source.id))
    ).all()

    download_receipts = settings.splitwise_receipt_download_enabled
    token = await _select_token(session, None) if download_receipts else None

    new_group = Group(name=body.name or source.name, backend_type=BackendType.self_hosted)
    session.add(new_group)
    await session.flush()

    pairs: list[tuple[Expense, Expense]] = []
    for expense in expenses:
        clone = Expense(
            group_id=new_group.id,
            description=expense.description,
            amount=expense.amount,
            currency=expense.currency,
            date=expense.date,
            category=expense.category,
            notes=expense.notes,
            created_by=expense.created_by,
            updated_by=expense.updated_by,
            splitwise_created_at=expense.splitwise_created_at,
            splitwise_updated_at=expense.splitwise_updated_at,
        )
        clone.splits = [
            Split(user_identifier=s.user_identifier, paid_share=s.paid_share, owed_share=s.owed_share)
            for s in expense.splits
        ]
        clone.items = [
            ExpenseItem(name=i.name, quantity=i.quantity, price=i.price, category=i.category)
            for i in expense.items
        ]
        session.add(clone)
        pairs.append((expense, clone))

    await session.flush()  # assign clone ids before attaching receipts

    receipts_downloaded = 0
    for source_expense, clone in pairs:
        for receipt in source_expense.receipts:
            await _copy_uploaded_receipt(session, receipt, clone.id)
        if download_receipts and token is not None and source_expense.splitwise_receipt_url:
            if await sw_receipts.download_to_minio(
                session, expense_id=clone.id,
                receipt_url=source_expense.splitwise_receipt_url, access_token=token.access_token,
            ):
                receipts_downloaded += 1

    for member in members:
        session.add(GroupMember(group_id=new_group.id, user_identifier=member.user_identifier))

    source.archived_at = datetime.now(timezone.utc)
    await session.commit()
    await session.refresh(new_group)
    return LocalImportResult(
        group=GroupResponse.model_validate(new_group),
        expenses_copied=len(expenses),
        receipts_downloaded=receipts_downloaded,
    )


@router.post("/groups/{group_id}/download-receipts", response_model=ReceiptDownloadResult)
async def download_group_receipts(
    group_id: UUID, session: AsyncSession = Depends(get_session)
) -> ReceiptDownloadResult:
    """Standalone flow: download original Splitwise receipt images for a group's expenses into MinIO as
    native Receipt rows. Gated by SPLITWISE_RECEIPT_DOWNLOAD_ENABLED; skips expenses that already have
    a receipt (idempotent)."""
    if not settings.splitwise_receipt_download_enabled:
        return ReceiptDownloadResult(downloaded=0, skipped=0, enabled=False)
    if await session.get(Group, group_id) is None:
        raise HTTPException(status_code=404, detail="Group not found")
    token = await _select_token(session, None)
    expenses = (
        await session.scalars(
            select(Expense)
            .where(
                Expense.group_id == group_id,
                Expense.archived_at.is_(None),
                Expense.splitwise_receipt_url.is_not(None),
            )
            .options(selectinload(Expense.receipts))
        )
    ).all()
    downloaded = skipped = 0
    for expense in expenses:
        if expense.receipts:
            skipped += 1
            continue
        if await sw_receipts.download_to_minio(
            session, expense_id=expense.id,
            receipt_url=expense.splitwise_receipt_url, access_token=token.access_token,
        ):
            downloaded += 1
        else:
            skipped += 1
    await session.commit()
    return ReceiptDownloadResult(downloaded=downloaded, skipped=skipped, enabled=True)
