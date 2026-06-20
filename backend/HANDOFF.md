# SplitBack Backend — Handoff: two-way Splitwise + lightweight roster

This document briefs a Claude Code instance (or Matt) on a Linux box with Docker to implement an
**approved** backend change. It is self-contained: the investigation, decisions, file pointers, and
patterns below were gathered on Matt's Mac (where Docker Desktop was unavailable, so build/test moved
to Linux). Per the workspace CLAUDE.md convention, this refers to **Matt** (the human) and **Claude**
(any assisting instance) and avoids pronouns.

The full approved plan also lives at `/Users/matt/.claude/plans/inherited-wobbling-aurora.md` (Mac);
this file reproduces what matters so the Linux instance needs nothing else.

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
