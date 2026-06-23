from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Core
    app_name: str = "SplitBack"
    default_currency: str = "USD"
    # Friendly label for this backend on the iOS join/confirm screen (e.g. "Matt's Household").
    # Surfaced by the unguarded GET /server-info; defaults to app_name when blank.
    public_hostname: str = ""
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
    # Sign-in allowlist (emails, JSON list e.g. ["a@x.com","b@y.com"]). Empty = anyone verified may sign in.
    # When set, only these emails may authenticate — enforced at sign-in AND on every request.
    auth_allowed_users: list[str] = []
    # When true, never create a NEW user at sign-in — only identities that already resolve to an existing
    # user (by provider sub/email) may sign in. Linking a second provider to an existing user still works.
    closed_registration: bool = False
    google_client_id: str = ""  # Google iOS OAuth client id — the id-token audience
    apple_audience: str = ""  # the iOS app bundle id (e.g. com.splitback.app) — the identity-token audience
    # Apple Developer Team ID — used to serve the App Site Association (GET /.well-known/apple-app-site-association)
    # for Universal Links. AASA returns 404 until this is set. appID = "<team_id>.<apple_audience>".
    apple_team_id: str = ""

    # Postgres
    database_url: str = "postgresql+asyncpg://splitback:splitback@db:5432/splitback"

    # MinIO (server-side only; iOS app never sees these)
    minio_endpoint: str = "minio:9000"
    minio_access_key: str = "splitback"
    minio_secret_key: str = "splitback-secret"
    minio_bucket: str = "receipts"
    minio_secure: bool = False

    # Backups (admin-only): full DB dump + receipt objects, stored as one tar.gz per backup in this MinIO
    # bucket (parallel to the receipts bucket; set per stack, e.g. backups-prod). The in-process scheduler
    # runs every `backup_interval_hours` (0 = off; enable on prod only) and then prunes: scheduled backups
    # older than `backups_retention_days` are deleted, but the newest `backups_retention_min_keep` are always
    # kept, and manual backups are never auto-deleted.
    backups_bucket: str = "backups"
    backup_interval_hours: int = 0
    backups_retention_days: int = 30
    backups_retention_min_keep: int = 7

    # Periodic data sync: the in-process scheduler runs Plaid (cursor-incremental) + Splitwise (incremental,
    # per stored token) every `sync_interval_hours` (0 = off; enable on prod, e.g. 12). Pull-to-refresh in the
    # app still only reconciles local data — this keeps the backend fresh without user action.
    sync_interval_hours: int = 0
    # When true, downloading original Splitwise receipt images into MinIO is enabled (convert-to-local
    # auto-downloads them, and the /download-receipts flow works). Off by default (bandwidth/storage).
    splitwise_receipt_download_enabled: bool = False

    # Subscription brand logos: the upstream a logo is fetched from (cached in MinIO, served by /logos).
    # `{domain}` is substituted. Default is a free, token-less favicon service; logo.dev gives nicer logos
    # with an API token, e.g. "https://img.logo.dev/{domain}?token=YOUR_TOKEN".
    logo_upstream_template: str = "https://www.google.com/s2/favicons?domain={domain}&sz=128"

    # Plaid (server-side only)
    plaid_client_id: str = ""
    plaid_secret: str = ""
    plaid_env: str = "development"
    plaid_products: str = "transactions"
    plaid_country_codes: str = "US"
    plaid_language: str = "en"
    # OAuth redirect URI for Plaid Link (required by most production banks). Must be registered in the
    # Plaid dashboard AND handled by the iOS app. Leave blank for sandbox / non-OAuth — only passed
    # to link-token creation when set (an unregistered value breaks ALL link tokens).
    plaid_redirect_uri: str = ""
    # Initial transaction history requested at link time (Plaid `days_requested`, max 730 = ~24 months).
    # Burned in per item at link; existing items only gain history by re-linking (POST /plaid/relink).
    plaid_transactions_days_requested: int = 730

    # Splitwise (server-side only) — consumer key/secret act as the OAuth2 client id/secret
    splitwise_consumer_key: str = ""
    splitwise_consumer_secret: str = ""
    splitwise_redirect_uri: str = "http://localhost:8000/auth/splitwise/callback"
    # Maps Splitwise user id (string) -> local identifier, e.g. {"123": "matt", "456": "nikki"}
    splitwise_user_map: dict[str, str] = {}

    # Field-encryption keys for access tokens at rest (Fernet). JSON list; the FIRST encrypts, ANY can
    # decrypt (rotation). Empty = stored plaintext (dev). Generate one with:
    #   python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
    encryption_keys: list[str] = []
    # Local identifiers granted admin (see all people; reserved for gating settings/features). Set to your
    # /me identifier (Settings -> Account shows it). Empty = no admins.
    admin_users: list[str] = []
    # Demo backend: enables the guest login (POST /auth/demo, name only — no OAuth) that mints an ephemeral
    # user and auto-seeds isolated sample data. Surfaced on /server-info so the app shows the demo UX. Keep
    # FALSE on dev/prod (the endpoint 404s when off).
    demo_mode: bool = False

    @property
    def libpq_dsn(self) -> str:
        """A plain libpq connection URI (for pg_dump/pg_restore), derived from the SQLAlchemy async URL by
        dropping the `+asyncpg` driver tag. Credentials stay embedded so no PGPASSWORD wiring is needed."""
        return self.database_url.replace("+asyncpg", "", 1)

    @model_validator(mode="after")
    def _require_strong_jwt_secret(self) -> "Settings":
        # When auth is enforced, an empty/short HS256 secret makes session tokens forgeable (PyJWT will
        # happily sign/verify with ""). Fail fast at startup rather than silently accept it.
        if self.auth_required and len(self.auth_jwt_secret) < 32:
            raise ValueError(
                "AUTH_JWT_SECRET must be set to >=32 chars when AUTH_REQUIRED=true "
                "(generate one with `openssl rand -hex 32`)."
            )
        return self


settings = Settings()
