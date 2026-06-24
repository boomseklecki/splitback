from decimal import Decimal

from pydantic import BaseModel


class BalanceEntry(BaseModel):
    identifier: str
    display_name: str | None
    paid_total: Decimal
    owed_total: Decimal
    net: Decimal  # net > 0 => owed to this person; net < 0 => this person owes


class FriendBalance(BaseModel):
    identifier: str
    display_name: str | None
    net: Decimal  # the caller's pairwise net with this person; net > 0 => this person owes the caller
