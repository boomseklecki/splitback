"""MinIO storage helpers.

A single internal client (in-cluster `minio:9000`) handles all object IO. Receipt bytes
flow through the API — the iOS client never reaches MinIO directly, so there is no public
client and no presigning. All calls here are blocking — wrap in asyncio.to_thread.
"""
from functools import lru_cache
from io import BytesIO
from uuid import UUID, uuid4

from minio import Minio
from minio.error import S3Error

from app.config import settings

# Extension by content type so stored keys keep a recognizable suffix.
_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/heic": ".heic",
    "image/webp": ".webp",
    "application/pdf": ".pdf",
}


@lru_cache
def _internal_client() -> Minio:
    return Minio(
        settings.minio_endpoint,
        access_key=settings.minio_access_key,
        secret_key=settings.minio_secret_key,
        secure=settings.minio_secure,
    )


def build_object_key(expense_id: UUID, content_type: str | None) -> str:
    return f"{expense_id}/{uuid4()}{_EXTENSIONS.get(content_type or '', '')}"


def ensure_bucket() -> None:
    client = _internal_client()
    if not client.bucket_exists(settings.minio_bucket):
        client.make_bucket(settings.minio_bucket)


def put_object(object_key: str, data: bytes, content_type: str | None) -> None:
    _internal_client().put_object(
        settings.minio_bucket,
        object_key,
        BytesIO(data),
        length=len(data),
        content_type=content_type or "application/octet-stream",
    )


def get_bytes(object_key: str) -> bytes:
    response = _internal_client().get_object(settings.minio_bucket, object_key)
    try:
        return response.read()
    finally:
        response.close()
        response.release_conn()


def object_exists(object_key: str) -> bool:
    try:
        _internal_client().stat_object(settings.minio_bucket, object_key)
        return True
    except S3Error:
        return False


def remove(object_key: str) -> None:
    _internal_client().remove_object(settings.minio_bucket, object_key)
