from pydantic import BaseModel

from app.schemas.group import GroupResponse


class SplitwiseStatus(BaseModel):
    connected: bool
    users: list[str]


class LocalImportRequest(BaseModel):
    name: str | None = None  # defaults to the source group's name


class LocalImportResult(BaseModel):
    group: GroupResponse
    expenses_copied: int


class SplitwiseImportRequest(BaseModel):
    since: str | None = None  # dated_after, e.g. 2020-01-01
    until: str | None = None  # dated_before
    as_user: str | None = None
    dry_run: bool = False


class SplitwiseImportResult(BaseModel):
    groups: int
    expenses_fetched: int
    imported: int
    skipped_deleted: int
    settle_ups: int
    dry_run: bool
    users: int | None = None
