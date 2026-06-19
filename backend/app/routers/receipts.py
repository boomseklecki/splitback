import asyncio
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_session
from app.integrations.storage import minio_client
from app.models import Expense, Receipt
from app.schemas.receipt import ReceiptResponse

router = APIRouter(tags=["receipts"])

_BINARY_BODY = {
    "content": {"application/octet-stream": {"schema": {"type": "string", "format": "binary"}}},
    "required": True,
}
_BINARY_RESPONSE = {
    200: {
        "content": {
            "application/octet-stream": {"schema": {"type": "string", "format": "binary"}}
        }
    }
}


async def _get_expense_or_404(session: AsyncSession, expense_id: UUID) -> Expense:
    expense = await session.get(Expense, expense_id)
    if expense is None:
        raise HTTPException(status_code=404, detail="Expense not found")
    return expense


@router.post(
    "/expenses/{expense_id}/receipts",
    response_model=ReceiptResponse,
    status_code=201,
    openapi_extra={"requestBody": _BINARY_BODY},
)
async def upload_receipt(
    expense_id: UUID, request: Request, session: AsyncSession = Depends(get_session)
) -> Receipt:
    await _get_expense_or_404(session, expense_id)
    content_type = request.headers.get("content-type") or "application/octet-stream"
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="Empty request body")

    object_key = minio_client.build_object_key(expense_id, content_type)
    await asyncio.to_thread(minio_client.put_object, object_key, data, content_type)

    receipt = Receipt(
        expense_id=expense_id,
        bucket=settings.minio_bucket,
        object_key=object_key,
        content_type=content_type,
    )
    session.add(receipt)
    await session.commit()
    await session.refresh(receipt)
    return receipt


@router.get("/expenses/{expense_id}/receipts", response_model=list[ReceiptResponse])
async def list_receipts(
    expense_id: UUID, session: AsyncSession = Depends(get_session)
) -> list[Receipt]:
    rows = await session.scalars(
        select(Receipt).where(Receipt.expense_id == expense_id).order_by(Receipt.created_at)
    )
    return list(rows)


@router.get(
    "/receipts/{receipt_id}/content",
    response_class=Response,
    responses=_BINARY_RESPONSE,
)
async def download_receipt(
    receipt_id: UUID, session: AsyncSession = Depends(get_session)
) -> Response:
    receipt = await session.get(Receipt, receipt_id)
    if receipt is None:
        raise HTTPException(status_code=404, detail="Receipt not found")
    data = await asyncio.to_thread(minio_client.get_bytes, receipt.object_key)
    return Response(content=data, media_type=receipt.content_type or "application/octet-stream")


@router.delete("/receipts/{receipt_id}", status_code=204)
async def delete_receipt(
    receipt_id: UUID, session: AsyncSession = Depends(get_session)
) -> None:
    receipt = await session.get(Receipt, receipt_id)
    if receipt is None:
        raise HTTPException(status_code=404, detail="Receipt not found")
    await asyncio.to_thread(minio_client.remove, receipt.object_key)
    await session.delete(receipt)
    await session.commit()
