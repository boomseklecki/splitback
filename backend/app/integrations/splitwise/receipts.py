"""Download original Splitwise receipt images into MinIO as native Receipt rows.

Splitwise receipts live behind an authenticated API URL, so they can't be loaded by the app and are
lost when a group is converted to local. This persists a local copy (mirrors the receipt upload path).
"""
import asyncio
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.integrations.splitwise import client as sw_client
from app.integrations.storage import minio_client
from app.models import Receipt


async def download_to_minio(
    session: AsyncSession, *, expense_id: UUID, receipt_url: str, access_token: str
) -> bool:
    """Fetch the receipt's original-size image with the OAuth token and store it in MinIO as a Receipt
    attached to `expense_id`. Best-effort: returns True on success, False on any failure (so one bad
    receipt never aborts a batch). Adds the row to the session; the caller commits."""
    url = sw_client.receipt_url_with_size(receipt_url, "original")
    try:
        content, content_type = await asyncio.to_thread(
            sw_client.fetch_receipt_bytes, access_token, url
        )
    except Exception:
        return False
    await asyncio.to_thread(minio_client.ensure_bucket)
    object_key = minio_client.build_object_key(expense_id, content_type)
    await asyncio.to_thread(minio_client.put_object, object_key, content, content_type)
    session.add(
        Receipt(
            expense_id=expense_id,
            bucket=settings.minio_bucket,
            object_key=object_key,
            content_type=content_type,
        )
    )
    return True
