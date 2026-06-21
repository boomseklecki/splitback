# SplitBack Backend — Handoff: two-way Splitwise + lightweight roster

This document briefs a Claude Code instance (or Matt) on a Linux box with Docker to implement an
**approved** backend change. It is self-contained: the investigation, decisions, file pointers, and
patterns below were gathered on Matt's Mac (where Docker Desktop was unavailable, so build/test moved
to Linux). Per the workspace CLAUDE.md convention, this refers to **Matt** (the human) and **Claude**
(any assisting instance) and avoids pronouns.

The full approved plan also lives at `/Users/matt/.claude/plans/inherited-wobbling-aurora.md` (Mac);
this file reproduces what matters so the Linux instance needs nothing else.

---

## NEW WORK — demo backend for TestFlight (guest login + per-tester seed) (2026-06-21)

A public, disposable **demo** stack so TestFlight testers explore the app with sample data before linking
real accounts. Guest login (no OAuth), per-tester isolated auto-seed, Plaid **sandbox**, no Splitwise.

- **`docker-compose.yml`**: `demo` profile — `db-demo` (volume `db_data_demo`) + `api-demo` (`:8002`,
  `env_file: .env.demo`, `DATABASE_URL`→`db-demo`, `MINIO_BUCKET=receipts-demo`), shared `minio`.
- **`.env.demo.example`** → copy to `.env.demo`: `DEMO_MODE=true`, `AUTH_REQUIRED=true` + a **fresh**
  `AUTH_JWT_SECRET`, `AUTH_ALLOWED_USERS=[]`, `PLAID_ENV=sandbox` + sandbox creds, **no Splitwise creds**.
- **`POST /auth/demo`** (`app/routers/auth.py`, **404 unless `DEMO_MODE`**): body `{display_name?}` → mints
  `demo-<hex>` user + `seed_identity` (isolated sample app) → returns a JWT. Allowlist-exempt by design.
- **`app/integrations/dev_seed/seeder.py::seed_identity`**: idempotent per-identity seed (groups + scoped
  accounts/transactions/goals); reused by `seed_dev` (now seeds only the `--as` self; robin/sam/alex are
  directory-only co-members). **`ServerInfo.demo`** exposes the flag to the app.
- **`app/cli/prune_demo.py`**: cron-prune `demo-*` users older than `--days` (+ their data).
- **Tests:** `tests/test_demo.py` (`seed_identity` idempotent; `/auth/demo` gated + seeds).

**Linux steps (uplink):**
1. `cp .env.demo.example .env.demo`; fill sandbox Plaid creds + a fresh `AUTH_JWT_SECRET`.
2. `docker compose --profile demo up -d` then `docker compose exec api-demo alembic upgrade head`;
   `curl localhost:8002/health`.
3. Add the Cloudflare hostname `demo.splitback.app → http://api-demo:8000`, then bring up `--profile tunnel`.
4. Smoke: `POST /auth/demo {"display_name":"Casey"}` → token; with it `/me` is the guest and
   `/accounts` + `/groups` are populated + isolated; confirm `/auth/demo` **404s** on prod/dev.
5. Run `tests/test_demo.py` + `tests/test_dev_seed.py`. Cron: `python -m app.cli.prune_demo --days 7`.

---

## NEW WORK — token encryption at rest + /users co-member scoping + admin flag (2026-06-21)

- **Encrypt access tokens (Fernet)**: `app/security/crypto.py::EncryptedString` applied to
  `plaid_items.access_token` + `splitwise_tokens.access_token`; `ENCRYPTION_KEYS` config (JSON list,
  rotatable via MultiFernet; empty = plaintext for dev). Migration **`0021_encrypt_tokens`** widens both
  columns to Text and encrypts existing rows when a key is set (idempotent). Test
  `tests/test_token_encryption.py`.
- **/users scoping + admin**: `GET /users` / `/users/{id}` now null `email`/`splitwise_user_id` for anyone
  who isn't you, a group co-member, or (new) an **admin**. `ADMIN_USERS` config (local identifiers) +
  `auth.access.is_admin`; surfaced on `MeResponse.is_admin` and the iOS `CurrentUser.isAdmin`. Contract
  change (additive `is_admin`, not required) — hand-edited into the committed `openapi.json`. Tests in
  `tests/test_scoping.py`.

**Linux steps:**
1. Set `ENCRYPTION_KEYS` (and `ADMIN_USERS`) in `.env`/`.env.prod` **before** `alembic upgrade head` — 0021
   encrypts existing tokens with the key.
2. Run `test_token_encryption.py` + `test_scoping.py`, and the **Plaid/Splitwise suites** — confirm sync/
   import still work (tokens decrypt for the SDKs; the `pg_insert ... on_conflict set_` token write must
   round-trip through `EncryptedString`). Spot-check `select access_token from plaid_items` = ciphertext.
3. Reconcile the real `GET /openapi.json` (now includes `MeResponse.is_admin`) → `prepare_openapi.py`,
   expect the hand-applied delta.

---

## NEW WORK — v1.0 pre-TestFlight hardening (2026-06-21)

From the release audit. Backend changes (run/verify on uplink; py_compile clean here):
- **Account deletion** (`app/routers/users.py`): `DELETE /users/{id}` is now **self-only** (403 otherwise)
  and purges the user's PERSONAL data — Plaid items (token **revoked at Plaid** via new
  `PlaidClient.item_remove`, cascading their accounts), Splitwise token, owned accounts/transactions/goals,
  and group memberships. Shared group expenses/splits are **retained** (co-owned history). Test:
  `tests/test_account_deletion.py`. iOS adds a Settings "Delete Account" action.
- **Plaid unlink** (`app/routers/plaid.py::delete_item`) now calls `item_remove` (best-effort) before delete.
- **JWT secret guard** (`app/config.py`): startup `model_validator` raises if `AUTH_REQUIRED=true` and
  `AUTH_JWT_SECRET` is <32 chars (prevents forgeable HS256 tokens). Test in `tests/test_auth_access.py`.
- **email_verified** (`app/integrations/auth/{apple,google}.py` via `verified_email`): drops the email claim
  when the provider explicitly marks it unverified (it feeds the allowlist + identity linking).
- **Migration `0020` guard**: now **aborts** if rows would be left un-owned and `SCOPING_PRIMARY_OWNER` is
  unset, and the backfill is parameterized. So set `SCOPING_PRIMARY_OWNER` before `alembic upgrade head`
  (the upgrade errors clearly otherwise).

**Still open (deferred / needs decisions):** token encryption at rest (#4 — pick app-layer vs disk
encryption), `/users` PII trim (#8 — contract change, low for single-household), Postgres/MinIO backups (#9),
Plaid production go/no-go checklist (#10), TestFlight tester onboarding (#2 — demo backend vs presets),
CORS/headers + CI (nice-to-have). Prod data still needs `owner_identifier` reconciled to your `/me` id
(the "accounts disappeared" issue) as a release step.

---

## NEW WORK — auth allowlist + closed registration + per-caller data scoping (2026-06-21)

**Why:** the backend let any verified identity sign in and returned ALL data to every caller. Now: (1) an
email allowlist + closed registration gate who can authenticate, and (2) per-caller scoping so each user
sees only their own (accounts/transactions/goals, by `owner_identifier`) or shared-group (groups/expenses/
receipts/balances, by `GroupMember`) data. `/users`, `/categories`, `/category-map` stay shared. Scoping only
filters when a caller is authenticated (`require_auth` returns None in open mode → unscoped, so dev is
unaffected).

**Files (committed from the Mac; py_compile clean, can't run there):**
- `app/config.py` — `auth_allowed_users: list[str]`, `closed_registration: bool`.
- `app/auth/access.py` (new) — `is_allowed` (email-only); `identity.resolve_user` 403s off-list / closed-reg;
  `require_auth` re-checks every request (401).
- `app/auth/scope.py` (new) — `assert_owner` / `assert_group_member` / membership helpers (no-op when caller
  is None).
- `owner_identifier` on `models/account.py`, `transaction.py`, `goal.py`; migration **`0020_owner_scoping`**
  (adds columns + backfills: accounts←plaid_items.user_identifier, transactions←account, then NULL→
  `SCOPING_PRIMARY_OWNER`).
- Stamping: `integrations/plaid/sync.py` (account/transaction owner = the linker), `routers/plaid.py`
  (link-token/exchange use the **caller**, not the body's `user_identifier` — security fix), manual creates
  in `routers/accounts.py` + `goals.py`.
- Scoping + 403 guards across `routers/accounts.py`, `groups.py` (creator auto-joins), `expenses.py`,
  `goals.py`, `plaid.py`, `receipts.py`, `balances.py`.
- Tests: `tests/test_auth_access.py`, `tests/test_scoping.py`. iOS: `AccountRepository.refreshAccounts` now
  prunes cached accounts/transactions the scoped backend no longer returns (Mac-built, green).

**Linux steps (ORDER MATTERS):**
1. In `.env.prod` set `SCOPING_PRIMARY_OWNER=<your /me identifier>` and `AUTH_ALLOWED_USERS=["you@…"]`
   **before** migrating (the backfill uses it; otherwise your manual data is left NULL-owned → invisible).
2. `docker compose exec api-prod alembic upgrade head` (applies `0020`, backfills).
3. Run `tests/test_auth_access.py` + `tests/test_scoping.py` (test stack) — expect green.
4. Verify: a second allowed user sees only their own accounts/transactions/goals + shared groups; a stranger
   is refused at sign-in (403); cross-user id access → 403. No contract/openapi change.
   Set `CLOSED_REGISTRATION=true` once everyone's imported.

---

## NEW WORK — Splitwise import unifies users by splitwise_user_id/email (2026-06-20)

**Why:** the import resolved a participant's local identifier independently of sign-in (`mapper.resolve_user_identifier`: `user_map` → slugified first name), so an Apple/Google sign-in (`auth.identity.resolve_user`, which links by email) and a later import could create **two users with the same email** — e.g. `/me` = `mattseklecki` but the splits say `matt` → the iOS Splits screen shows no "you owe" amounts and won't hide settled groups (balances key off `/me`'s identifier).

**Change (committed from the Mac; runs on uplink):**
- `app/integrations/splitwise/importer.py` — new `_resolve_identifier(session, …)` that reuses an existing
  user: (1) by `splitwise_user_id`, (2) else by `email`, (3) else the old `mapper.resolve_user_identifier`
  fallback. Wired into `sync_groups`/`sync_users`/`sync_expenses`; in `sync_expenses` the resolved map is
  threaded into `mapper.map_expense(expense, {**user_map, **resolved})` so the **splits** carry the same
  identifier. No schema change; the readable string identifier stays.
- `tests/test_splitwise_user_unification.py` — reuse-by-email, reuse-by-sub, slug fallback, no-duplicate.

**Linux steps:**
1. Run the new test (test stack): expect green.
2. **One-time cleanup of the existing duplicate on prod** (the fix prevents new dups but won't merge old
   ones). Check: `select identifier, email, splitwise_user_id, source from users where email = '<you>';`
   If you see both `matt` (splitwise, owns the splits) and `mattseklecki` (app, your sign-in):
   - delete the app duplicate `delete from users where identifier='mattseklecki';` then **re-import**
     (`docker compose exec api-prod python -m app.cli.import_splitwise --since <date>`) — the import now
     resolves by email and rewrites the splits to your sign-in identifier; **or**
   - simpler, sign in via **Splitwise** on prod (so `/me` = `matt`, matching the existing splits) and delete
     the stray `mattseklecki`.
   Confirm with the iOS Settings → Account `ID:` line that `/me` now matches the splits.

---

## NEW WORK — two stacks: dev (sandbox) + production (real Plaid) + synthetic dev seed (2026-06-20)

**Goal:** keep the **existing stack as DEVELOPMENT** (sandbox Plaid data stays; its real Splitwise import is
wiped and replaced with synthetic data), and stand up a **new PRODUCTION stack** with real Plaid. Code +
compose written on the Mac (not runnable there). Run on uplink.

Services are **explicit**: `db-dev`/`api-dev` (default, :8001, sandbox) and `db-prod`/`api-prod`
(`--profile prod`, :8000, real Plaid). On the existing box, `git pull` + `docker compose up -d` replaces the
old `api`/`db` containers with `api-dev`/`db-dev` which **reuse the same `db_data`/`minio_data` volumes — no
data loss**; the dev LAN port just moves :8000 → :8001 (or use `https://dev.splitback.app`).

**Files added/changed (committed from the Mac):**
- `docker-compose.yml` — renamed default services to `db-dev`/`api-dev` (:8001, `env_file: .env`,
  PLAID_ENV=sandbox, existing `db_data` volume); added a **`prod` profile**: `db-prod` (volume `db_data_prod`)
  + `api-prod` (:8000, `env_file: .env.prod`, `DATABASE_URL`→`db-prod`, `MINIO_BUCKET=receipts-prod`), shared
  `minio`. `cloudflared` documents two public hostnames.
- `.env.prod.example` — production template (PLAID_ENV=production, redirect URI, a **fresh** AUTH_JWT_SECRET,
  prod Splitwise app/redirect). `.env.prod` is gitignored.
- `app/integrations/dev_seed/generator.py` — pure synthetic generator (deterministic; splits balanced).
- `app/cli/seed_dev.py` — seeds the dev DB; `--wipe` clears groups/members/foreign-users/Splitwise-tokens
  (keeps the self identifier) but NEVER touches accounts/transactions/plaid_items.
- `tests/test_dev_seed.py` — generator invariants + wipe-preserves-bank-data (run on the test DB).

**Cloudflare:** add a second public hostname so each stack has its own URL (DNS auto-created):
`splitback.app → http://api-prod:8000` and `dev.splitback.app → http://api-dev:8000` (internal compose
targets; the iOS app uses the public https hostnames as its Settings Dev/Prod presets).

**Dev steps (existing stack, on uplink):**
1. In `.env` confirm `PLAID_ENV=sandbox`. `docker compose up -d` (now starts `db-dev`/`minio`/`api-dev`).
2. Wipe real Splitwise + load synthetic data: `docker compose exec api-dev python -m app.cli.seed_dev --as matt --wipe`.
   (Use the real self identifier for `--as` so you still sign into dev as yourself.) Re-run anytime to reset.
3. Run the new tests against the test stack: `docker compose --profile test run --rm api-test python -m tests.test_dev_seed` (or however the suite is run on uplink).

**Production bring-up (new stack, on uplink):**
1. Prereqs (Plaid dashboard, user-side): production access approved; `https://splitback.app/plaid/oauth`
   registered as a production redirect URI.
2. `cp .env.prod.example .env.prod`; fill production Plaid secret + redirect, a fresh `AUTH_JWT_SECRET`,
   production Splitwise app creds + `https://splitback.app/auth/splitwise/callback`, `PUBLIC_HOSTNAME`.
3. `docker compose --profile prod up -d` (starts dev + prod) then `docker compose exec api-prod alembic upgrade head`; `curl localhost:8000/health` (prod) / `:8001/health` (dev).
4. Point the iOS app at prod (Settings → Backend, Prod preset = `https://splitback.app`) → re-link real banks
   via Plaid Link (production access tokens are new — sandbox links don't carry over) → sync. Re-import real
   Splitwise INTO prod: `docker compose exec api-prod python -m app.cli.import_splitwise --since <date>`
   (after authorizing Splitwise against the prod stack via `/auth/splitwise/login`).
5. Expose prod publicly: add the `splitback.app → http://api-prod:8000` tunnel hostname (above), then
   `docker compose --profile prod --profile tunnel up -d`.

No DB migration or contract change in this work (the seed uses existing tables; `GET /openapi.json` unchanged).

---

## NEW WORK — transaction line items (code written on Mac 2026-06-20; VERIFY + MIGRATE on Linux)

**What:** itemize a single bank/manual transaction across categories (mirror of `expense_items`, but
**no owner** — a transaction is wholly the viewer's). The iOS side is done, built, and green on the Mac
against a hand-edited contract. The backend code below was written on the Mac but **could not be run
there** (no Python/SQLAlchemy/Docker). It mirrors the `expense_items` patterns exactly. The Linux box
must run the migration and the test suite, then confirm the deployed `/openapi.json` matches the
hand-applied contract delta.

**Files already added/edited (committed from the Mac):**
- `app/models/transaction_item.py` — `TransactionItem` (`transaction_id` FK→`transactions` CASCADE,
  `name`, `quantity` Numeric(10,3) default 1, `price` Numeric(12,2), `category`, `created_by`,
  `updated_by`). No `owner_identifier`.
- `app/models/transaction.py` — added `items` relationship (`cascade="all, delete-orphan",
  passive_deletes=True`). Registered in `app/models/__init__.py`.
- `migrations/versions/0019_transaction_items.py` — `create_table("transaction_items", …)`,
  down_revision `0018_expense_item_meta`.
- `app/schemas/transaction.py` — `TransactionItemInput` / `TransactionItemResponse`; `items:
  list[TransactionItemResponse] = []` on `TransactionResponse`.
- `app/routers/accounts.py` — `selectinload(Transaction.items)` on the list + a `_load_transaction`
  helper used by GET-detail / POST / PATCH / the new PUT (async sessions can't lazy-load after the
  query); **`PUT /transactions/{id}/items`** (`_apply_transaction_items` upsert-by-id, drop-orphan).
  Kept off PATCH so it never trips the category-override "omitted = clear" behavior.
- `tests/test_transaction_items.py` — PUT roundtrip, upsert-by-id keeps identity + recategorizes,
  drop-orphan, GET returns items, transaction delete cascades items.

**Linux steps:**
1. `alembic upgrade head` (applies `0019_transaction_items`).
2. Run the suite (incl. `tests/test_transaction_items.py`) against a running API — expect green.
3. `configure_mappers()` / app import sanity (catches any relationship typo the Mac couldn't).
4. `GET /openapi.json` → run `ios/scripts/prepare_openapi.py` and diff against the committed
   `ios/SplitBackAPI/Sources/SplitBackAPI/openapi.json` — expect **zero diff** (the Mac added
   `TransactionItemInput`/`TransactionItemResponse`, `TransactionResponse.items` (optional, NOT in
   `required` so older responses still decode), and the `PUT /transactions/{transaction_id}/items`
   path with operationId `set_transaction_items_transactions__transaction_id__items_put`).

Plaid never provides line items — these are purely user-authored (receipt itemization in the iOS app).

---

## STATUS — implemented (as built, 2026-06-19)

All four gaps are closed and the suite is green (55 tests). The build deviated from the original
plan below in three confirmed ways (Matt approved each); the plan text further down is kept for
context but **this section is authoritative where they conflict**.

- **Roster (Workstreams 1–2): done, but shaped differently.** Built as a **`User`** model / `users`
  table / `/users` CRUD + **`/me`** (not `Participant`/`participants`). It carries a `source` enum
  (`app`|`manual`|`splitwise`) and `email` beyond the plan's fields. An **explicit `group_members`
  table** + `/groups/{id}/members` endpoints were kept (the plan wanted these derived from splits and
  no table — Matt chose to keep the explicit table). Splitwise import upserts `users` (with
  `splitwise_user_id`, never downgrading an `app` user) and `group_members`. Migration is
  `0005_users_members` (not `0005_participants`).
- **Two-way Splitwise sync (Workstream 3): done, integrated.** Write path lives in
  `integrations/splitwise/writer.py` (`build_payload` pure; `select_token` payer-first;
  `push_create/push_update/push_delete`) + client `create_expense`/`update_expense`/`delete_expense`.
  It is **wired directly into `routers/expenses.py`** create/update/delete (push-first: Splitwise call
  then stamp `splitwise_expense_id` then commit; update heals a pre-existing phantom by creating).
  There is **no** manual `/expenses/{id}/splitwise-push` endpoint. Errors map to **422** (participant
  missing `splitwise_user_id`), **409** (no token), **502** (upstream Splitwise).
- **Split validation — REVISED decision.** Validation stays **self-hosted-only**; Splitwise groups
  **defer to Splitwise** (do NOT enable `_validate_splits` for them). Rationale: with push-first,
  Splitwise is the authority — an invalid expense is rejected upstream (→ 502) and nothing is stored
  locally, so a local check adds no correctness, and our ±0.01 rule could diverge from Splitwise's
  actual rules and falsely reject. (This supersedes the original plan's "enable validation for
  Splitwise groups".)
- **Session extras kept** (not in the original plan, approved separately): `/balances`,
  `/categories`, manual `/accounts` + `/transactions`, `/plaid/items`, `updated_since` incremental
  sync, `/splitwise/status` + `/import`.
- **Expense soft-delete + Splitwise-aware delete (added 2026-06-19).** `expenses.archived_at`
  (migration `0006_expense_archive`) + `EXPENSES_HARD_DELETE_ENABLED` config flag, mirroring the
  groups flag. `DELETE /expenses/{id}` now branches by expense kind, with an optional `?propagate=`
  override:
  - **local-only** (`splitwise_expense_id IS NULL`) → archive by default; hard-delete (+ MinIO
    cleanup) when the flag is on. The flag governs ONLY these.
  - **Splitwise-linked, active group** → propagate the delete to Splitwise (keeps balances in
    parity); `?propagate=false` archives locally instead.
  - **Splitwise-linked, archived group** → archive locally (it's retired; leave the friends' data
    on Splitwise alone); `?propagate=true` forces propagation.
  Archived expenses are excluded from `GET /expenses` (folded into the existing `include_archived`
  param) and from `/balances` + `/groups/{id}/balances`; `GET /expenses/{id}` still returns them.
  Rationale: archiving a Splitwise-linked expense in an *active* group would silently desync
  SplitBack's balance from Splitwise's authoritative ledger — so that case propagates by default.
- **Import a Splitwise group into a local group (added 2026-06-19).**
  `POST /splitwise/groups/{group_id}/import-local` `{name?}` clones an already-imported Splitwise
  group into a NEW self-hosted group: active expenses copied as **native** rows
  (`splitwise_expense_id = NULL`, splits + line items carried), group members copied, then the
  **source group is archived** so balances don't double-count. Archived source expenses are skipped.
  400 if the source is not a Splitwise group. One-shot create (not an idempotent sync); run
  `/splitwise/import` first to refresh the source from Splitwise.
- **Receipts now proxy through the API (changed 2026-06-19).** The presigned-URL flow was dropped so
  the iOS client reaches a single host (its configured API base URL) instead of also needing the
  MinIO public host. `POST /expenses/{id}/receipts` now takes the **raw image bytes**
  (`application/octet-stream`, real type via `Content-Type`) and stores them in one call;
  `GET /receipts/{id}/content` streams the bytes back. The old `/receipts/upload-url`,
  register-by-`object_key`, and `/receipts/{id}/download-url` routes are gone, as are the
  `MINIO_PUBLIC_ENDPOINT` / `MINIO_PUBLIC_SECURE` / `MINIO_PRESIGN_EXPIRY_SECONDS` settings and the
  storage layer's public/presign client. MinIO is reached only by the api container over the
  in-cluster name. **Route count is now 32 paths / 46 operations** (was 33).
- **Real auth — Apple / Google / Splitwise → backend JWT (added 2026-06-19).** Providers verified
  server-side, then the backend issues its own stateless HS256 JWT (~90d). Migration `0007_user_auth`
  adds `users.apple_sub` / `google_sub` (unique) + `avatar_url`. New: `app/auth/` package
  (`tokens.issue/verify`, `identity.resolve_user` — find-by-sub / link-by-email / create),
  `app/integrations/auth/{apple,google}.py` (cached JWKS, RS256), `client.get_current_user` for
  Splitwise, `app/routers/auth.py` (`POST /auth/apple`, `POST /auth/google`, unguarded). The Splitwise
  callback now resolves the user and **redirects to `splitback://auth?token=<jwt>`** instead of
  returning JSON. `require_auth` accepts our JWT (→ user identifier) or a legacy `API_TOKENS` entry;
  enforces (401) when `AUTH_REQUIRED` or `API_TOKENS` is set, else open. `UserResponse`/`/me` carry
  `avatar_url`. New config: `AUTH_JWT_SECRET`, `AUTH_REQUIRED`, `GOOGLE_CLIENT_ID`, `APPLE_AUDIENCE`
  (empty defaults = open mode; see README "Authentication"). Provider verification is unit-tested with
  JWKS/SDK mocked; live verification awaits real creds. **Route count now 34 paths / 48 operations.**
- **Incremental Splitwise sync + scoped refresh endpoints (added 2026-06-19).** `run_import` split into
  reusable, independently-committing phases in `importer.py` (`sync_groups` / `sync_users` /
  `sync_expenses`) — so a mid-sync failure no longer rolls back the whole import. `sync_expenses` takes
  `updated_after` (delta-only; catches edits/settle-ups) and **archives locally** any expense Splitwise
  has deleted (new — old import only skipped deleted rows). New cursor `splitwise_tokens.expenses_synced_at`
  (migration `0010_sw_sync_cursor`); `client.fetch_expenses` gained `updated_after`/`updated_before`/
  `group_id`. New endpoints `POST /splitwise/sync/{groups,users,expenses}` (synchronous, for iOS
  pull-to-refresh) returning `SyncResult`; `/sync/expenses` reads/advances the cursor. `/import` stays the
  cold backfill and now stamps the cursor. Balances unchanged — still computed from synced splits
  (`balances.py`), no `simplified_debts`. Opt-in cron `app.cli.splitwise_sync` (mirrors `plaid_sync`).
  **Route count now 37 paths / 51 operations.**
- **Onboarding join link + Cloudflare tunnel exposure (added 2026-06-20, single-host).** The **backend
  serves the onboarding site itself** (no separate static host) — unguarded routes in
  `app/routers/public.py`: `GET /server-info` (`{app, version, name, requires_auth, auth_providers}`,
  the app's pre-adopt verify; `PUBLIC_HOSTNAME` = friendly label), `GET /join` (the static
  `app/static/join.html` — install + invite QR `splitback://configure?api=` + copyable endpoint; `?api=`
  defaults to the serving host), and `GET /.well-known/apple-app-site-association` (Universal Links,
  served `application/json`, generated from `APPLE_TEAM_ID` + `APPLE_AUDIENCE`; 404 until `APPLE_TEAM_ID`
  is set). The AASA/join routes are `include_in_schema=False` (browser/Apple-facing, not in the iOS
  contract). Tunnel: profile-gated `cloudflared` compose service
  (`docker compose --profile tunnel up -d cloudflared`) reading `CLOUDFLARE_TUNNEL_TOKEN` from `.env` —
  remotely-managed, dashboard hostname `splitback.app` → `http://api:8000`; the API never reads the
  token. So one public host does the API + join + AASA. iOS handler (associated domain = the public
  host, `splitback://configure`, confirm + Scan-invite) in `ios/HANDOFF.md`. Deferred: web admin portal
  + settings store, Docker-controlled tunnel on/off, separate static host (Cloudflare Pages).
- **iOS contract regenerated** via `ios/scripts/prepare_openapi.py` →
  `ios/SplitBackAPI/Sources/SplitBackAPI/openapi.json` (raw also at `ios/openapi.json`).

Remaining live-only verification (needs a real stored Splitwise token, as the plan's "Manual
end-to-end" section notes): `POST /expenses` into a Splitwise group → confirm it appears in Splitwise
and a re-import dedups it (no duplicate). The Splitwise create/update/delete propagation paths are
unit-tested with the SDK mocked; the actual network leg awaits real credentials.

## How Claude should start
1. Read this whole document. Skim `backend/app/routers/expenses.py`, `backend/app/routers/groups.py`,
   `backend/app/integrations/splitwise/{client,importer,mapper}.py`, and `backend/app/models/`.
2. Bring the stack up: from repo root `docker compose up -d --build` (services: `db` postgres:16,
   `minio`, `api` on `:8000`). Confirm `curl localhost:8000/health`.
3. Work the three workstreams below in order; build + run tests after each. Follow the workspace
   CLAUDE.md: minimal surgical edits, match existing patterns, no speculative abstractions.

## Why (the four confirmed gaps)
iOS Phase 1 is done; before iOS Phase 2 (split entry + create/edit expenses) Matt flagged backend
gaps. Investigation of `backend/app` confirmed:

1. **No user/identity model.** "Users" are free-form `user_identifier` strings on splits
   (`app/models/split.py:18`, `String(128)`). The only rosters are server config — `api_tokens`
   (`config.py:13`) and `splitwise_user_map` (`config.py:44`) — neither exposed via API. The iOS app
   has no way to ask "who are the people?".
2. **No group membership.** `app/models/group.py` has `expenses` but no members; membership is
   emergent from whoever appears in a split.
3. **Splitwise users not persisted.** Import reads Splitwise users (id, first name, shares in
   `integrations/splitwise/client.py:_normalize_expense`) but only translates user_id→identifier via
   the hand-edited `splitwise_user_map` (`integrations/splitwise/mapper.py:resolve_user_identifier`),
   discarding the user_id and names.
4. **No Splitwise write path.** `integrations/splitwise/client.py` is read-only (`getGroups`/
   `getExpenses`). `create_expense`/`update_expense` (`routers/expenses.py`) write to the **local DB
   for any backend type** with no guard, producing local-only phantoms (`splitwise_expense_id = NULL`)
   that never reach Splitwise and never round-trip through the importer.

## Decisions (confirmed by Matt)
- **Two-way Splitwise sync** — app edits must propagate to Splitwise (build the write path).
- **Lightweight roster** — persist people + Splitwise identity; **no** auth/registration/passwords and
  **no** per-group membership tables.
- **Backend first** — close these gaps, regenerate the contract, then do iOS Phase 2.

---

## Workstream 1 — Lightweight participant roster (gaps 1–3)

**Model** `app/models/participant.py` — follow `app/models/plaid_item.py` for style; mixins from
`app/models/base.py` (`UUIDMixin` gives `id` UUID PK via `gen_random_uuid()`, `TimestampMixin` gives
`created_at`/`updated_at`):
```
class Participant(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "participants"
    identifier: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)  # e.g. "matt"
    display_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    splitwise_user_id: Mapped[str | None] = mapped_column(String(64), unique=True, nullable=True)
```
Register it in `app/models/__init__.py` (add the import line; that file is what Alembic autogenerate
and the app both rely on). Keep the roster **global** — do NOT add an association table; a group's
people are derived from that group's splits joined to participants (lighter, enough for a 2-person
household, and covers gap 2).

**Schemas** `app/schemas/participant.py` — mirror `app/schemas/group.py`
(`ConfigDict(from_attributes=True)` on responses): `ParticipantResponse`, `ParticipantCreate`
(`identifier`, `display_name?`, `splitwise_user_id?`), `ParticipantUpdate` (all optional).

**Router** `app/routers/participants.py` — mirror `app/routers/groups.py` (`APIRouter(prefix=
"/participants", tags=["participants"])`). Endpoints:
- `GET /participants` → list roster.
- `POST /participants` → register a person (201).
- `PATCH /participants/{id}` → edit display_name / identifier / splitwise_user_id.
- `GET /groups/{group_id}/participants` → participants whose `identifier` appears in that group's
  splits (join `Split` → distinct `user_identifier` → `Participant`). Put this in the participants
  router (or groups router) — keep `prefix` in mind so the path resolves to `/groups/{id}/participants`.

Mount in `app/main.py` in the `_protected` block alongside `groups`, `expenses`, etc.

## Workstream 2 — Persist Splitwise users on import (gap 3)
In `integrations/splitwise/importer.py` (`_upsert_expense` / `run_import`) and/or `mapper.py`: before
writing splits, **upsert a `Participant` per Splitwise user** — store `splitwise_user_id` and
`display_name` (from `first_name`), with `identifier` resolved by `splitwise_user_map` override else
the normalized first name (reuse the existing `resolve_user_identifier` logic). `splitwise_user_map`
becomes an optional override seed, not the only source. Keep it idempotent (the importer is upsert-
based; see `test_splitwise_import_idempotency.py`). The Splitwise user dicts already carry `user_id`
and `first_name` (`client.py:_normalize_expense`).

## Workstream 3 — Splitwise write-back (gap 4, two-way)

**Confirm the SDK first** (`splitwise>=3.0`, `backend/pyproject.toml:15`). Run in the container:
```
docker compose exec api python -c "from splitwise import Splitwise; from splitwise.expense import Expense, ExpenseUser; \
print([m for m in dir(Splitwise) if 'xpense' in m]); print([m for m in dir(Expense) if m.startswith('set')]); \
print([m for m in dir(ExpenseUser) if m.startswith('set')])"
```
Expected (verify): `Splitwise.createExpense(expense) -> (expense, errors)`,
`updateExpense(expense)` (expense has `setId`), `deleteExpense(id) -> (success, errors)`; `Expense`
setters `setCost/setDescription/setGroupId/setDate/setCurrencyCode`; `ExpenseUser`
`setId/setPaidShare/setOwedShare`.

**Client writes** — extend `integrations/splitwise/client.py` with `create_expense(client, payload)
-> sw_id`, `update_expense(client, sw_id, payload)`, `delete_expense(client, sw_id)`, raising on the
SDK's `errors` return.

**Payload builder** `integrations/splitwise/writer.py` (pure-ish, mirror `mapper.py` so it's unit-
testable): translate a local `Expense` + `splits` → Splitwise payload. `group_id =
group.splitwise_group_id`; each split `user_identifier` → `participant.splitwise_user_id` (**raise →
422 if a split's participant has no `splitwise_user_id`**). Cost/description/date/currency from the
expense. Per-user `paid_share`/`owed_share` from splits.

**Token** — pick the `SplitwiseToken` (`app/models/splitwise_token.py`, stores per-identifier
`access_token`) of the payer (the split with `paid_share > 0`); else a configured primary; **409 if no
token is stored** (direct Matt to `/auth/splitwise/login` first).

**Wire `routers/expenses.py`** — when `group.backend_type == BackendType.splitwise`:
- create → call the writer/SDK first (via `asyncio.to_thread`, as the importer does), then set the
  returned `splitwise_expense_id` on the local row before commit (so re-import dedups — no phantom).
- update → push the update to Splitwise; delete → also `deleteExpense` on Splitwise.
- **Enable `_validate_splits` for Splitwise groups** (currently skipped at `expenses.py:79` and
  `:148`); two-way requires balanced splits and Splitwise enforces it too.
- Map SDK/HTTP failures → **502** (upstream Splitwise error) or **409** (conflict/no token).

Relevant request shapes are in `app/schemas/expense.py` (`SplitInput.user_identifier/paid_share/
owed_share`, `ExpenseCreate`, `ExpenseUpdate`). No schema changes needed for writes; `ExpenseResponse`
already exposes `splitwise_expense_id`.

## Migration
Migrations are **hand-written sequential files** (`migrations/versions/0001_initial.py` …
`0004_plaid_items.py`); autogenerate is wired (`migrations/env.py`, `target_metadata = Base.metadata`)
so `alembic revision --autogenerate -m participants` will draft it — then rename/clean to match the
pattern. New file `migrations/versions/0005_participants.py` with
`revision = "0005_participants"`, `down_revision = "0004_plaid_items"`, creating the `participants`
table (id uuid PK default `gen_random_uuid()`, `identifier` unique, `display_name`,
`splitwise_user_id` unique, timestamps). Verify `upgrade`/`downgrade` both run.

## Verification (Linux, Docker present)
- There is **no pytest** in the image; tests use `tests/_runner.py` (`python -m tests.<name>`).
  Integration tests need a **clean** DB, so run them against the `test` compose profile, not the dev
  `db` (which holds real imported data): `docker compose --profile test up -d db-test api-test` →
  `docker compose exec -T api-test alembic upgrade head` → `docker compose exec -T api-test sh run_tests.sh`.
  See README "Running tests". Extend the suite with:
  - participant upsert from import is idempotent and persists names (alongside
    `test_splitwise_import_idempotency.py`, `test_splitwise_mapper.py`);
  - pure Splitwise **payload builder** test (dict-based, like `test_splitwise_mapper.py`);
  - expense router on a Splitwise group sets `splitwise_expense_id` and calls the writer (**mock the
    SDK** — no live Splitwise in tests); split validation now enforced for Splitwise groups
    (extend `test_groups_expenses.py`);
  - `GET /participants` and `GET /groups/{id}/participants`.
- Migration: `docker compose exec api alembic upgrade head` then `... downgrade -1`.
- Manual end-to-end (needs a real stored Splitwise token): `POST /expenses` into a Splitwise group →
  confirm it appears in Splitwise and a re-import (`python -m app.cli.import_splitwise`) dedups it (no
  duplicate). `GET /participants` returns persisted Splitwise users.

## Then: regenerate the iOS contract (for Phase 2)
With the stack running:
```
curl -s localhost:8000/openapi.json > ios/openapi.json
python3 ios/scripts/prepare_openapi.py ios/openapi.json ios/SplitBackAPI/Sources/SplitBackAPI/openapi.json
```
The iOS client plumbing (Phase 1) already collapses FastAPI's nullable `anyOf` fields — see
`ios/scripts/prepare_openapi.py` and the note in `ios/SplitBackAPI/Sources/SplitBackAPI/
openapi-generator-config.yaml`. **Do not** hand-edit the generated copy. Rebuild the iOS app to pick
up the new participant types, then start iOS Phase 2.

## Out of scope (deferred)
Auth/registration/passwords, explicit per-group membership tables, Splitwise webhooks (inbound stays
pull-import via the CLI / `POST /plaid/sync`-style flows).

## Reference
- Patterns to copy: model `app/models/plaid_item.py`; schema `app/schemas/group.py`; router
  `app/routers/groups.py`; router mounting + auth `app/main.py` / `app/auth.py`.
- `app/config.py` — `default_currency`, `splitwise_user_map`, `api_tokens`, Splitwise consumer
  key/secret.
- iOS side: `ios/HANDOFF.md`, and the Phase 1 result (built, green) under `ios/`.
