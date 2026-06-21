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

The default stack is **development** (`api-dev` on :8001, `db-dev`, `PLAID_ENV=sandbox` in `.env`):

```bash
cp .env.example .env          # adjust if needed
docker compose up --build     # db-dev + minio + api-dev
```

- Dev API: http://localhost:8001 (docs at `/docs`)
- MinIO console: http://localhost:9001 (user `splitback`)

### Development + production side by side

Run a **production** stack (`api-prod` on :8000, real Plaid, its own DB volume + `receipts-prod` bucket)
alongside dev with the `prod` profile:

```bash
cp .env.prod.example .env.prod     # fill: production Plaid secret + redirect, a FRESH AUTH_JWT_SECRET, prod Splitwise
docker compose --profile prod up -d            # dev (:8001) + prod (:8000)
docker compose exec api-prod alembic upgrade head
```

The two stacks share nothing (separate Postgres volume + MinIO bucket). Expose both via one Cloudflare tunnel
with two public hostnames — `splitback.app → http://api-prod:8000` and `dev.splitback.app → http://api-dev:8000`
(those `api-*:8000` names are internal compose targets; the iOS app uses the public `https://` hostnames, set
once as the Settings Dev/Prod presets). To load safe synthetic sample data into **dev** (replacing any real
Splitwise import; bank data untouched):

```bash
docker compose exec api-dev python -m app.cli.seed_dev --as <your-identifier> --wipe
```

### Demo stack (TestFlight)

A public, disposable **demo** backend (`api-demo` on :8002, own DB volume + `receipts-demo` bucket) lets
TestFlight testers explore the app with sample data before linking real accounts. It runs guest login
(`DEMO_MODE` → `POST /auth/demo`, name only, no OAuth): each guest gets an isolated, auto-seeded sample app;
Plaid is **sandbox**; there is no Splitwise. Bring it up with the `demo` profile and a third Cloudflare
hostname (`demo.splitback.app → http://api-demo:8000`):

```bash
cp .env.demo.example .env.demo     # fill: sandbox Plaid creds, a FRESH AUTH_JWT_SECRET (DEMO_MODE=true preset)
docker compose --profile demo up -d
docker compose exec api-demo alembic upgrade head
```

Guest rows accumulate; prune old ones on a cron to bound growth:

```bash
docker compose exec api-demo python -m app.cli.prune_demo --days 7
```

## Apply migrations

Once a stack is up, run Alembic inside its api container (`api-dev` for dev, `api-prod` for prod):

```bash
docker compose exec api-dev alembic upgrade head
```

Health checks:

```bash
curl localhost:8001/health        # dev app liveness (prod: :8000)
curl localhost:8001/health/db     # database reachability
```

API docs (all endpoints) at http://localhost:8001/docs (dev) / http://localhost:8000/docs (prod).

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
2. On the tunnel, add a **public hostname** for each stack (Cloudflare auto-creates the DNS records).
   The service is the compose service name on its own container port `:8000` — the connector shares the
   stacks' network:
   - `splitback.app` → `http://api-prod:8000` (production)
   - `dev.splitback.app` → `http://api-dev:8000` (development)
   - `demo.splitback.app` → `http://api-demo:8000` (demo)
3. Put the token in `.env`: `CLOUDFLARE_TUNNEL_TOKEN=<token>`.
4. Start the connector: `docker compose --profile tunnel up -d cloudflared`.

Manage/disable the tunnel and its routes on the Cloudflare website thereafter. The API never sees the
token (it's compose-only). Those public hostnames are what you set as the app's Dev/Prod server URLs
(Settings → Backend presets).

## Sharing the app (join link)

The **backend serves the onboarding site itself** (no separate static host) — your public hostname does
double duty for the API and the join page. Share one link:

```
https://splitback.app/join                       # endpoint defaults to this host
https://splitback.app/join?name=Your%20Household  # optional friendlier label
```

The backend serves, all unguarded:
- `GET /join` — install button (TestFlight/App Store), an invite **QR** (`splitback://configure?api=…`)
  for the app's "Scan invite", and the server URL as copyable text. `?api=` overrides the endpoint
  (defaults to the host serving the page); `?name=` sets the label.
- `GET /.well-known/apple-app-site-association` — the Universal-Link association, served as
  `application/json`, generated from `APPLE_TEAM_ID` + `APPLE_AUDIENCE` (appID = `<team>.<bundle>`).
  Returns 404 until `APPLE_TEAM_ID` is set. With the app installed, tapping the link opens it and
  pre-fills the endpoint; otherwise the page guides installation.
- `GET /server-info` (`{app, version, name, requires_auth, auth_providers}`) — pinged by the app to
  verify a URL is a real SplitBack server before adopting it (`PUBLIC_HOSTNAME` sets the friendly label).

The iOS app's `applinks:` associated domain must match this public hostname. After exposing the backend
(tunnel above), verify the AASA: `curl -I https://splitback.app/.well-known/apple-app-site-association`
should show `content-type: application/json` over HTTPS with no redirect (set `APPLE_TEAM_ID` first).

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

Use the target stack's api container (`api-prod` for production, `api-dev` for development):

```bash
# One-time Splitwise backfill (after authorizing via /auth/splitwise/login)
docker compose exec api-prod python -m app.cli.import_splitwise --dry-run

# Incremental Splitwise expense sync for all tokens (delta-only; suitable for a gentle cron)
docker compose exec api-prod python -m app.cli.splitwise_sync

# Plaid transaction sync for all linked items (suitable for cron)
docker compose exec api-prod python -m app.cli.plaid_sync
```

## Local dev (without Docker)

```bash
cd backend
uv sync
# point DATABASE_URL at a reachable Postgres, then:
uv run alembic upgrade head
uv run uvicorn app.main:app --reload
```
