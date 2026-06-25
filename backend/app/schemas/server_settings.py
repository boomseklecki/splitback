from pydantic import BaseModel


class ServerSettingsResponse(BaseModel):
    """The full server-settings registry resolved to current values."""
    invites_open_to_members: bool
    public_hostname: str
    groups_hard_delete_enabled: bool
    expenses_hard_delete_enabled: bool
    splitwise_receipt_download_enabled: bool
    sync_interval_hours: int
    backup_interval_hours: int
    backups_retention_days: int
    backups_retention_min_keep: int


class ServerSettingsUpdate(BaseModel):
    """Any subset of the registry; only provided keys change (PATCH semantics)."""
    invites_open_to_members: bool | None = None
    public_hostname: str | None = None
    groups_hard_delete_enabled: bool | None = None
    expenses_hard_delete_enabled: bool | None = None
    splitwise_receipt_download_enabled: bool | None = None
    sync_interval_hours: int | None = None
    backup_interval_hours: int | None = None
    backups_retention_days: int | None = None
    backups_retention_min_keep: int | None = None
