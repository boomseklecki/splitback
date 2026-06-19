from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Core
    app_name: str = "SplitBack"
    default_currency: str = "USD"
    # When true, DELETE /groups/{id} hard-deletes (cascade + MinIO cleanup) instead of archiving.
    groups_hard_delete_enabled: bool = False
    # Governs local-only (non-Splitwise) expenses: when true, DELETE /expenses/{id} hard-deletes
    # (MinIO cleanup) instead of archiving. Splitwise-linked expenses follow group state /
    # the ?propagate= override instead of this flag.
    expenses_hard_delete_enabled: bool = False
    # Maps bearer token -> local identifier, e.g. {"tok-matt": "matt", "tok-nikki": "nikki"}.
    # Empty = auth disabled (open mode); populated = bearer token required on app endpoints.
    api_tokens: dict[str, str] = {}

    # Real auth: providers (Apple/Google/Splitwise) verified server-side, then the backend issues
    # its own stateless JWT. `auth_required` default false keeps dev/tests/open mode working.
    auth_jwt_secret: str = ""  # HS256 signing secret; generate a long random value (openssl rand -hex 32)
    auth_required: bool = False  # when true, guarded endpoints reject requests without a valid token
    google_client_id: str = ""  # Google iOS OAuth client id — the id-token audience
    apple_audience: str = ""  # the iOS app bundle id (e.g. com.splitback.app) — the identity-token audience

    # Postgres
    database_url: str = "postgresql+asyncpg://splitback:splitback@db:5432/splitback"

    # MinIO (server-side only; iOS app never sees these)
    minio_endpoint: str = "minio:9000"
    minio_access_key: str = "splitback"
    minio_secret_key: str = "splitback-secret"
    minio_bucket: str = "receipts"
    minio_secure: bool = False

    # Plaid (server-side only)
    plaid_client_id: str = ""
    plaid_secret: str = ""
    plaid_env: str = "development"
    plaid_products: str = "transactions"
    plaid_country_codes: str = "US"
    plaid_language: str = "en"

    # Splitwise (server-side only) — consumer key/secret act as the OAuth2 client id/secret
    splitwise_consumer_key: str = ""
    splitwise_consumer_secret: str = ""
    splitwise_redirect_uri: str = "http://localhost:8000/auth/splitwise/callback"
    # Maps Splitwise user id (string) -> local identifier, e.g. {"123": "matt", "456": "nikki"}
    splitwise_user_map: dict[str, str] = {}


settings = Settings()
