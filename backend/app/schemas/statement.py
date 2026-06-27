from uuid import UUID

from pydantic import BaseModel


class StatementImportResult(BaseModel):
    account_id: UUID
    account_name: str
    imported: int  # new transactions added
    skipped: int   # already present (FITID dedup)
    total: int     # transactions in the statement
