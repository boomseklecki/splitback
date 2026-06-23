"""Admin backup engine.

A backup is a full, restorable snapshot of one stack = a Postgres custom-format `pg_dump` plus every receipt
object, packed into a single `tar.gz` and stored in the backups bucket. The object is named
`<UTC-timestamp>__<kind>__<slug>.tar.gz`; `kind` (manual|scheduled) and the human `label` are also written to
object metadata. Restore brings the database (`pg_restore --clean`) and the receipts bucket back to the
snapshot, after first taking a `pre-restore` safety backup.

Everything here is heavy/blocking (a subprocess + object IO), so callers treat these as long-running. A module
lock serializes create/restore/prune so two never overlap (a concurrent restore would be unsafe). The raw
artifact never leaves the server — routers expose metadata only.
"""
from __future__ import annotations

import asyncio
import os
import re
import shutil
import tarfile
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from app.config import settings
from app.integrations.storage import minio_client

KIND_MANUAL = "manual"
KIND_SCHEDULED = "scheduled"

_DATABASE_DUMP = "database.dump"
_RECEIPTS_DIR = "receipts"
_lock = asyncio.Lock()

# Restore writes receipt objects back with a sensible content-type from their extension.
_CONTENT_TYPES = {
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
    ".heic": "image/heic", ".webp": "image/webp", ".pdf": "application/pdf",
}


@dataclass
class BackupInfo:
    name: str
    size_bytes: int
    created_at: datetime
    label: str | None
    kind: str


def _slug(label: str | None) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (label or "").lower()).strip("-")
    return s or "backup"


def _content_type(key: str) -> str:
    return _CONTENT_TYPES.get(os.path.splitext(key)[1].lower(), "application/octet-stream")


async def _run(*args: str) -> None:
    """Run a subprocess (pg_dump/pg_restore), raising with captured stderr on a non-zero exit."""
    proc = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    _, stderr = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(f"{args[0]} failed ({proc.returncode}): {stderr.decode(errors='replace')[:2000]}")


# --- Create -------------------------------------------------------------------------------------------

async def create(label: str | None = None, kind: str = KIND_MANUAL) -> BackupInfo:
    async with _lock:
        return await _create_unlocked(label=label, kind=kind)


async def _create_unlocked(label: str | None, kind: str) -> BackupInfo:
    workdir = await asyncio.to_thread(tempfile.mkdtemp, prefix="splitback-backup-")
    try:
        dump_path = os.path.join(workdir, _DATABASE_DUMP)
        await _run("pg_dump", "-Fc", "-d", settings.libpq_dsn, "-f", dump_path)
        await asyncio.to_thread(_download_receipts, os.path.join(workdir, _RECEIPTS_DIR))

        archive = os.path.join(workdir, "archive.tar.gz")
        await asyncio.to_thread(_pack, workdir, archive)

        created = datetime.now(timezone.utc)
        name = f"{created.strftime('%Y%m%dT%H%M%SZ')}__{kind}__{_slug(label)}.tar.gz"
        await asyncio.to_thread(minio_client.ensure_bucket_named, settings.backups_bucket)
        await asyncio.to_thread(
            minio_client.upload_file, settings.backups_bucket, name, archive,
            "application/gzip", {"kind": kind, "label": label or ""})
        return BackupInfo(name=name, size_bytes=os.path.getsize(archive), created_at=created,
                          label=label or None, kind=kind)
    finally:
        await asyncio.to_thread(shutil.rmtree, workdir, ignore_errors=True)


def _download_receipts(dest: str) -> None:
    os.makedirs(dest, exist_ok=True)
    for key in minio_client.list_object_names(settings.minio_bucket):
        target = os.path.join(dest, key)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        minio_client.download_to_file(settings.minio_bucket, key, target)


def _pack(workdir: str, archive: str) -> None:
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(os.path.join(workdir, _DATABASE_DUMP), arcname=_DATABASE_DUMP)
        receipts = os.path.join(workdir, _RECEIPTS_DIR)
        if os.path.isdir(receipts):
            tar.add(receipts, arcname=_RECEIPTS_DIR)


# --- List ---------------------------------------------------------------------------------------------

async def list_backups() -> list[BackupInfo]:
    return await asyncio.to_thread(_list_blocking)


def _list_blocking() -> list[BackupInfo]:
    infos: list[BackupInfo] = []
    for name in minio_client.list_object_names(settings.backups_bucket):
        size, modified, meta = minio_client.stat(settings.backups_bucket, name)
        kind, label = _kind_label(name, meta)
        infos.append(BackupInfo(name=name, size_bytes=size, created_at=modified, label=label, kind=kind))
    infos.sort(key=lambda b: b.created_at, reverse=True)
    return infos


def _kind_label(name: str, meta: dict[str, str]) -> tuple[str, str | None]:
    """Recover (kind, label) from object metadata (minio prefixes user metadata with `x-amz-meta-`),
    falling back to the kind encoded in the object name."""
    lowered = {k.lower(): v for k, v in meta.items()}
    kind = lowered.get("x-amz-meta-kind") or lowered.get("kind")
    label = lowered.get("x-amz-meta-label") or lowered.get("label")
    if not kind:
        parts = name.split("__")
        kind = parts[1] if len(parts) >= 2 else KIND_MANUAL
    return kind, (label or None)


# --- Restore / delete ---------------------------------------------------------------------------------

async def restore(name: str) -> dict[str, str]:
    async with _lock:
        safety = await _create_unlocked(label="pre-restore", kind=KIND_MANUAL)
        workdir = await asyncio.to_thread(tempfile.mkdtemp, prefix="splitback-restore-")
        try:
            archive = os.path.join(workdir, "archive.tar.gz")
            await asyncio.to_thread(minio_client.download_to_file, settings.backups_bucket, name, archive)
            await asyncio.to_thread(_unpack, archive, workdir)
            await _run("pg_restore", "--clean", "--if-exists", "--no-owner",
                       "-d", settings.libpq_dsn, os.path.join(workdir, _DATABASE_DUMP))
            await asyncio.to_thread(_restore_receipts, os.path.join(workdir, _RECEIPTS_DIR))
            return {"restored": name, "safety_backup": safety.name}
        finally:
            await asyncio.to_thread(shutil.rmtree, workdir, ignore_errors=True)


def _unpack(archive: str, dest: str) -> None:
    with tarfile.open(archive, "r:gz") as tar:
        tar.extractall(dest)  # trusted artifact (we produced it)


def _restore_receipts(src: str) -> None:
    if not os.path.isdir(src):
        return
    minio_client.ensure_bucket_named(settings.minio_bucket)
    for root, _dirs, files in os.walk(src):
        for fname in files:
            full = os.path.join(root, fname)
            key = os.path.relpath(full, src)
            minio_client.upload_file(settings.minio_bucket, key, full, _content_type(key))


async def delete(name: str) -> None:
    await asyncio.to_thread(minio_client.remove_named, settings.backups_bucket, name)


# --- Prune (retention) --------------------------------------------------------------------------------

async def prune(now: datetime | None = None) -> list[str]:
    doomed = select_prunable(await list_backups(), settings.backups_retention_days,
                             settings.backups_retention_min_keep, now or datetime.now(timezone.utc))
    for name in doomed:
        await asyncio.to_thread(minio_client.remove_named, settings.backups_bucket, name)
    return doomed


def select_prunable(infos: list[BackupInfo], retention_days: int, min_keep: int,
                    now: datetime) -> list[str]:
    """Names to delete: among SCHEDULED backups (newest first), always keep the first `min_keep`, then drop
    any older than `retention_days`. Manual backups are never selected."""
    scheduled = sorted((b for b in infos if b.kind == KIND_SCHEDULED),
                       key=lambda b: b.created_at, reverse=True)
    cutoff = now - timedelta(days=retention_days)
    return [b.name for i, b in enumerate(scheduled) if i >= min_keep and b.created_at < cutoff]
