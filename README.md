# SplitBack

Self-hosted, iOS-native personal finance + expense-splitting backend. See [PLAN.md](PLAN.md) for the full project plan.

This repo contains the **backend**: Postgres schema, FastAPI app, and the local Docker stack. Implemented so far:

- **Groups & expenses CRUD** — nested splits/items, ±0.01 balance validation (self-hosted groups), soft-delete (archive) + hide flags, `backend_type` filter.
- **Receipts** — image bytes proxied through the API to/from MinIO (`POST /expenses/{id}/receipts`, `GET /receipts/{id}/content`); the client never reaches MinIO directly.
- **Splitwise** — OAuth2 + PKCE auth, historical import (`app.cli.import_splitwise`), and **incremental sync**: scoped pull-to-refresh endpoints (`POST /splitwise/sync/{groups,users,expenses}`) where the expenses pull is delta-only via `updated_after` (a cursor on `splitwise_tokens`) and archives expenses Splitwise has deleted. `POST /splitwise/import` is the one-time backfill.
- **Plaid** — link/exchange, incremental `/transactions/sync`, accounts/transactions read endpoints (`app.cli.plaid_sync`).
- **Auth** — sign in with Apple / Google / Splitwise; the backend verifies the provider token, find-or-creates the `User`, and issues its own stateless JWT (`POST /auth/apple`, `POST /auth/google`, Splitwise via the OAuth callback). See [Authentication](#authentication).

Live Splitwise/Plaid calls need real credentials + outbound network (set in `.env`). The iOS client is not built yet.

## Stack

- Python 3.12 + FastAPI (async)
- SQLAlchemy 2.0 (async) + asyncpg
- Alembic migrations
- Postgres 16, MinIO (S3-compatible receipt storage)
- `uv` for dependency management

## Layout

```
docker-compose.yml      # postgres + minio + api
.env.example            # config keys (copy to .env)
backend/
  app/
    main.py             # FastAPI app + /health
    config.py           # settings (pydantic-settings)
    db.py               # async engine + session dependency
    models/             # SQLAlchemy ORM: groups, accounts, transactions,
                        # expenses, expense_items, splits, receipts
    routers/health.py
  migrations/           # Alembic (0001_initial creates all 7 tables)
```

## Run the stack

```bash
cp .env.example .env          # adjust if needed
docker compose up --build
```

- API: http://localhost:8000 (docs at `/docs`)
- MinIO console: http://localhost:9001 (user `splitback`)

## Apply migrations

Once the stack is up, run Alembic inside the api container:

```bash
docker compose exec api alembic upgrade head
```

Health checks:

```bash
curl localhost:8000/health        # app liveness
curl localhost:8000/health/db     # database reachability
```

API docs (all endpoints) at http://localhost:8000/docs.

## Authentication

People self-register by signing in with **Apple, Google, or Splitwise**. The backend verifies the
provider token server-side, find-or-creates/links a `User` (linking a second provider by matching
email), and issues its **own stateless JWT** (HS256, ~90-day expiry). The iOS app stores that JWT and
sends `Authorization: Bearer <jwt>` on every request.

- `POST /auth/apple` — body `{identity_token, full_name?}` → `{token, user}`
- `POST /auth/google` — body `{id_token}` → `{token, user}`
- Splitwise: `GET /auth/splitwise/login` → consent → `GET /auth/splitwise/callback` redirects to
  `splitback://auth?token=<jwt>` (the app catches the custom scheme via `ASWebAuthenticationSession`).

Enforcement is **default-open** for local dev/tests: set `AUTH_REQUIRED=true` (or configure the legacy
`API_TOKENS` map) to require a valid token on guarded endpoints. Revoke all sessions by rotating
`AUTH_JWT_SECRET`. Refresh tokens and email+password are deferred.

### Configuration

Set these in `.env` (see `.env.example`):

| Key | Value |
| --- | --- |
| `AUTH_JWT_SECRET` | HS256 signing secret. Generate: `openssl rand -hex 32` |
| `AUTH_REQUIRED` | `false` (open) or `true` (enforce) |
| `GOOGLE_CLIENT_ID` | Google OAuth **iOS** client id (`…apps.googleusercontent.com`) — the ID-token audience |
| `APPLE_AUDIENCE` | the iOS app **bundle id** (e.g. `com.splitback.app`) — the identity-token audience |

### Getting the provider credentials

**Sign in with Apple** (native iOS; the backend only needs the audience)
1. Apple Developer → Certificates, Identifiers & Profiles → **Identifiers** → the app's App ID
   (e.g. `com.splitback.app`) → enable **Sign in with Apple** → Save.
2. (Xcode) add the **Sign in with Apple** capability to the app target.
3. Set `APPLE_AUDIENCE` to the bundle id. Native token verification needs **no** client secret or
   Services ID (those are only for the web redirect flow, which SplitBack doesn't use).

**Google Sign-In** (the iOS client id is the token audience)
1. Google Cloud Console → create/select a project.
2. APIs & Services → **OAuth consent screen** → External; set app name + support email; scopes
   `openid`, `email`, `profile`; add test users (or publish).
3. APIs & Services → **Credentials** → Create credentials → **OAuth client ID** → Application type
   **iOS** → bundle id `com.splitback.app`.
4. Copy the generated **iOS client ID** (`…apps.googleusercontent.com`) into `GOOGLE_CLIENT_ID`. No
   client secret is needed for iOS ID-token verification.

**Splitwise** uses the existing `SPLITWISE_CONSUMER_KEY` / `SPLITWISE_CONSUMER_SECRET` / redirect URI.

## Public access via Cloudflare Tunnel

To reach the backend from outside your LAN (so the iOS app works anywhere), expose it with a Cloudflare
tunnel. Use a **remotely-managed** tunnel so everything stays manageable from the Cloudflare dashboard:

1. Cloudflare **Zero Trust → Networks → Tunnels → Create a tunnel** → **Cloudflared** → name it →
   **copy the connector token**.
2. On the tunnel, add a **public hostname**: your domain (e.g. `splitback.app`) → service
   `http://api:8000`. Cloudflare auto-creates the DNS record. (`api:8000` is the compose service name —
   the connector shares the API's network.)
3. Put the token in `.env`: `CLOUDFLARE_TUNNEL_TOKEN=<token>`.
4. Start the connector: `docker compose --profile tunnel up -d cloudflared`.

Manage/disable the tunnel and its routes on the Cloudflare website thereafter. The API never sees the
token (it's compose-only). That public hostname is what you hand out as the app's server URL (below).

## Sharing the app (join link)

The repo's `web/` directory is a static site (deploy to Cloudflare Pages at a fixed domain, e.g.
`splitback.app`) that lets people install the app and point it at your backend in one link:

```
https://splitback.app/join?api=https://<your-public-hostname>&name=Your%20Household
```

- `web/join/index.html` — install button (TestFlight/App Store), an invite **QR** (`splitback://configure?api=…`)
  for the app's "Scan invite", and the server URL as copyable text.
- `web/.well-known/apple-app-site-association` — the Universal-Link association; replace `TEAMID` with
  your Apple Developer **Team ID** (the app's `applinks:` entitlement uses the same domain). With the app
  installed, tapping the link opens it and pre-fills the endpoint; otherwise the page guides installation.

- `web/_headers` — forces `Content-Type: application/json` on the AASA (it has no file extension, so
  Cloudflare won't infer it). **Required** — Universal Links silently fail without it.

The backend exposes an unguarded `GET /server-info` (`{app, version, name, requires_auth, auth_providers}`)
that the app pings to verify a URL is a real SplitBack server before adopting it (`PUBLIC_HOSTNAME` sets
the friendly label).

### Deploy the join site (Cloudflare Pages)

Cloudflare folded Pages into "Workers & Pages"; the CLI is the most reliable path:

```bash
npx wrangler login                                   # one-time browser auth
npx wrangler pages deploy web --project-name splitback
```

Then in the Pages project → **Custom domains** → add the apex `splitback.app` (the tunnel uses a separate
subdomain like `api.splitback.app`). Re-run the deploy command to publish updates. Verify the AASA after
deploy: `curl -I https://splitback.app/.well-known/apple-app-site-association` should show
`content-type: application/json` over HTTPS with no redirect.

## Running tests

The suite includes integration tests that drive the running API + DB, so they must run against a
**clean** database — not the dev `db` (which may hold real Splitwise/imported data). A `test` compose
profile provides an ephemeral Postgres (`db-test`) + a second API (`api-test`) pointed at it:

```bash
docker compose --profile test up -d db-test api-test   # ephemeral DB; dev `db` untouched
docker compose exec -T api-test alembic upgrade head    # migrate the clean DB
docker compose exec -T api-test sh run_tests.sh         # run every tests/test_*.py
```

`run_tests.sh` exits non-zero if any module fails. Tear down with
`docker compose --profile test down` (the `tmpfs` DB is discarded). There is no pytest in the image;
each `tests/test_*.py` is runnable standalone via `python -m tests.<name>`.

## Background jobs

```bash
# One-time Splitwise backfill (after authorizing via /auth/splitwise/login)
docker compose exec api python -m app.cli.import_splitwise --dry-run

# Incremental Splitwise expense sync for all tokens (delta-only; suitable for a gentle cron)
docker compose exec api python -m app.cli.splitwise_sync

# Plaid transaction sync for all linked items (suitable for cron)
docker compose exec api python -m app.cli.plaid_sync
```

## Local dev (without Docker)

```bash
cd backend
uv sync
# point DATABASE_URL at a reachable Postgres, then:
uv run alembic upgrade head
uv run uvicorn app.main:app --reload
```
