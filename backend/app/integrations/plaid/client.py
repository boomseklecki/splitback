"""Plaid SDK wrapper.

Responses are converted to plain dicts via `.to_dict()` so the rest of the code
never touches Plaid model objects. All methods are blocking — call via to_thread.
"""
import plaid
from plaid.api import plaid_api
from plaid.model.accounts_get_request import AccountsGetRequest
from plaid.model.country_code import CountryCode
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
from plaid.model.products import Products
from plaid.model.transactions_sync_request import TransactionsSyncRequest

from app.config import settings


def _build_api() -> plaid_api.PlaidApi:
    host = getattr(plaid.Environment, settings.plaid_env.capitalize(), plaid.Environment.Sandbox)
    configuration = plaid.Configuration(
        host=host,
        api_key={"clientId": settings.plaid_client_id, "secret": settings.plaid_secret},
    )
    return plaid_api.PlaidApi(plaid.ApiClient(configuration))


def _normalize_account(account: dict) -> dict:
    balances = account.get("balances") or {}
    return {
        "plaid_account_id": account.get("account_id"),
        "name": account.get("name") or account.get("official_name"),
        "type": str(account.get("subtype") or account.get("type") or "") or None,
        "balance": balances.get("current"),
        "currency": balances.get("iso_currency_code") or "USD",
    }


def _transaction_category(transaction: dict) -> str | None:
    """Plaid's category. Prefers the current `personal_finance_category` taxonomy (the legacy
    `category` array is deprecated and comes back null on modern items) — `detailed` first so we can
    tell e.g. groceries from restaurants, then `primary`, then the legacy array as a last resort."""
    pfc = transaction.get("personal_finance_category") or {}
    if isinstance(pfc, dict):
        detailed = pfc.get("detailed") or pfc.get("primary")
        if detailed:
            return detailed
    legacy = transaction.get("category")
    return legacy[0] if isinstance(legacy, list) and legacy else None


def _normalize_transaction(transaction: dict) -> dict:
    return {
        "plaid_transaction_id": transaction.get("transaction_id"),
        "plaid_account_id": transaction.get("account_id"),
        "description": transaction.get("name") or transaction.get("merchant_name") or "",
        "amount": transaction.get("amount"),
        "currency": transaction.get("iso_currency_code") or "USD",
        "date": transaction.get("date"),
        "category": _transaction_category(transaction),
        "pending": transaction.get("pending", False),
    }


class PlaidClient:
    def __init__(self) -> None:
        self._api = _build_api()

    def create_link_token(self, user_identifier: str) -> str:
        request = LinkTokenCreateRequest(
            user=LinkTokenCreateRequestUser(client_user_id=user_identifier),
            client_name=settings.app_name,
            products=[Products(p.strip()) for p in settings.plaid_products.split(",")],
            country_codes=[CountryCode(c.strip()) for c in settings.plaid_country_codes.split(",")],
            language=settings.plaid_language,
        )
        return self._api.link_token_create(request).to_dict()["link_token"]

    def exchange_public_token(self, public_token: str) -> tuple[str, str]:
        response = self._api.item_public_token_exchange(
            ItemPublicTokenExchangeRequest(public_token=public_token)
        ).to_dict()
        return response["access_token"], response["item_id"]

    def get_accounts(self, access_token: str) -> list[dict]:
        response = self._api.accounts_get(
            AccountsGetRequest(access_token=access_token)
        ).to_dict()
        return [_normalize_account(a) for a in response["accounts"]]

    def fetch_transactions_page(self, access_token: str, cursor: str | None) -> dict:
        kwargs = {"access_token": access_token}
        if cursor:
            kwargs["cursor"] = cursor
        response = self._api.transactions_sync(TransactionsSyncRequest(**kwargs)).to_dict()
        return {
            "added": [_normalize_transaction(t) for t in response["added"]],
            "modified": [_normalize_transaction(t) for t in response["modified"]],
            "removed": [t["transaction_id"] for t in response["removed"]],
            "next_cursor": response["next_cursor"],
            "has_more": response["has_more"],
        }


def make_client() -> PlaidClient:
    return PlaidClient()
