from datetime import datetime

from pydantic import BaseModel


class BackupResponse(BaseModel):
    name: str
    size_bytes: int
    created_at: datetime
    label: str | None
    kind: str  # "manual" | "scheduled"


class BackupCreate(BaseModel):
    label: str | None = None


class RestoreResult(BaseModel):
    restored: str       # the backup that was restored
    safety_backup: str  # the pre-restore safety backup taken first
