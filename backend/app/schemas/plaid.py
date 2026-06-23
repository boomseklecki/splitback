from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from app.schemas.account import AccountResponse


class PlaidItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    plaid_item_id: str
    institution_name: str | None
    user_identifier: str | None
    accounts: list[AccountResponse] = []
    created_at: datetime
    updated_at: datetime


class LinkTokenRequest(BaseModel):
    user_identifier: str = "matt"


class LinkTokenResponse(BaseModel):
    link_token: str


class ExchangeRequest(BaseModel):
    public_token: str
    user_identifier: str = "matt"
    institution_name: str | None = None


class ExchangeResponse(BaseModel):
    item_id: UUID
    plaid_item_id: str
    accounts: list[AccountResponse]


class SyncRequest(BaseModel):
    item_id: UUID | None = None
    # When true, clears the saved cursor first so transactions are re-pulled from scratch (used to
    # backfill fields like category after a mapping change).
    reset: bool = False


class SyncResponse(BaseModel):
    items_synced: int
    accounts: int
    added: int
    modified: int
    removed: int


class RelinkRequest(BaseModel):
    # The existing item to extend; replaced by a fresh link that pulls more history, then merged onto it.
    old_item_id: UUID
    public_token: str
    institution_name: str | None = None


class RelinkResult(BaseModel):
    accounts_matched: int
    transactions_merged: int   # recent overlap de-duplicated (edits/links carried to the new rows)
    transactions_kept: int     # user-meaningful old rows with no new match, re-parented
    links_moved: int           # expense<->transaction links re-pointed to the new transactions
    items_synced: int
