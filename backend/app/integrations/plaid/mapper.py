"""Pure mapping from normalized Plaid dicts to SplitBack row data.

Amount-sign convention: Plaid reports a POSITIVE amount for money leaving the
account (outflow) and negative for inflow. We store it as-is; consumers interpret
the sign rather than us flipping it here.
"""
from datetime import date, datetime
from decimal import Decimal


def _parse_date(value) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    return datetime.fromisoformat(str(value).replace("Z", "+00:00")).date()


def map_account(account: dict) -> dict:
    return {
        "plaid_account_id": account["plaid_account_id"],
        "name": account.get("name") or "Account",
        "type": account.get("type"),
        "balance": Decimal(str(account.get("balance") if account.get("balance") is not None else "0")),
        "currency": account.get("currency") or "USD",
    }


def map_transaction(transaction: dict) -> dict:
    return {
        "plaid_transaction_id": transaction["plaid_transaction_id"],
        "plaid_account_id": transaction.get("plaid_account_id"),
        "description": transaction.get("description") or "",
        "amount": Decimal(str(transaction.get("amount") if transaction.get("amount") is not None else "0")),
        "currency": transaction.get("currency") or "USD",
        "date": _parse_date(transaction.get("date")),
        "category": transaction.get("category"),
        "pending": bool(transaction.get("pending")),
    }
