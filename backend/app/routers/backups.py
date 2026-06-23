"""Admin-only backup management: create / list / restore / delete full-stack backups (DB + receipts).

Every route is gated by `require_admin`. The raw artifact is never returned — only metadata and actions.
Create and restore are long-running (a pg_dump/pg_restore + receipt IO); the iOS client calls these on its
300s "slow" transport.
"""
from fastapi import APIRouter, Depends

from app.auth import require_admin
from app.schemas.backup import BackupCreate, BackupResponse, RestoreResult
from app.services import backups

router = APIRouter(tags=["backups"])


def _response(info: backups.BackupInfo) -> BackupResponse:
    return BackupResponse(name=info.name, size_bytes=info.size_bytes, created_at=info.created_at,
                          label=info.label, kind=info.kind)


@router.get("/backups", response_model=list[BackupResponse])
async def list_backups(_: str = Depends(require_admin)) -> list[BackupResponse]:
    return [_response(b) for b in await backups.list_backups()]


@router.post("/backups", response_model=BackupResponse, status_code=201)
async def create_backup(body: BackupCreate, _: str = Depends(require_admin)) -> BackupResponse:
    return _response(await backups.create(label=body.label, kind=backups.KIND_MANUAL))


@router.post("/backups/{name}/restore", response_model=RestoreResult)
async def restore_backup(name: str, _: str = Depends(require_admin)) -> RestoreResult:
    return RestoreResult(**await backups.restore(name))


@router.delete("/backups/{name}", status_code=204)
async def delete_backup(name: str, _: str = Depends(require_admin)) -> None:
    await backups.delete(name)
