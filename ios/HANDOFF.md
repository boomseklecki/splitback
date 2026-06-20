# SplitBack iOS — Handoff Spec

This document briefs a Claude Code instance running on Matt's MacBook (with Xcode) to build the SplitBack iOS app. The backend is complete and running; this app is the remaining frontier. Per the workspace CLAUDE.md convention, this document avoids pronouns and refers to **Matt** (the human) and **Claude** (any assisting instance).

## How Claude should start

1. Read this whole document and `ios/openapi.json` (the API contract) before writing code.
2. Enter plan mode and confirm the open decisions (see the last section) with Matt before implementation.
3. Work in phases (below). Build and run after each phase — verification is the whole point of moving this work to a Mac. Do not batch all phases before building.
4. Follow the workspace CLAUDE.md: minimal surgical edits, no speculative abstractions, plan before non-trivial code, ask when ambiguous.

## Context

SplitBack is a self-hosted, iOS-native personal finance + expense-splitting app (a Mint/Splitwise hybrid for a 2-person household, Matt + Nikki). The backend (FastAPI + Postgres + MinIO) is done and exposes a REST API documented by `ios/openapi.json` (OpenAPI 3.1.0). The product plan lives in `PLAN.md` at the repo root; the backend lives in `backend/`.

Core principle: the **server is the source of truth**. The app caches locally (SwiftData) and syncs against the API. Private (self-hosted) expenses are full-featured; shared expenses route through Splitwise via the backend. Plaid account/transaction sync is backend-only — the app reads accounts/transactions from the backend, never talks to Plaid directly except via the Plaid Link SDK during account linking.

## Backend API surface (from `ios/openapi.json`)

Base URL is configurable (local: `http://localhost:8000`; production: the Cloudflare tunnel hostname). The full set lives in `ios/openapi.json` (37 paths) — the highlights below. **Receipt bytes flow through this same base URL** — there is no separate MinIO host to reach or configure.

**Users & identity**
- `GET /me` — caller identity from the bearer token: `{identifier, authenticated, user}` (`user` carries `avatar_url`)

**Auth / sign-in** (unguarded; establishes the session)
- `POST /auth/apple` — `{identity_token, full_name?}` → `{token, user}`. Native Sign in with Apple: send the `ASAuthorizationAppleIDCredential.identityToken`; forward `full_name` on first consent.
- `POST /auth/google` — `{id_token}` → `{token, user}`. Send the Google Sign-In SDK's ID token.
- Splitwise: open `GET /auth/splitwise/login` in `ASWebAuthenticationSession` → on success the callback **redirects to `splitback://auth?token=<jwt>`**; parse the `token` from that callback URL.
- All three return our **stateless JWT** (~90-day). Store it in the Keychain and send `Authorization: Bearer <jwt>` on every request. The backend issues its own JWT (Apple/Google/Splitwise are only verified, never trusted directly).
- `GET /users?source=`, `POST /users` (manual people; `identifier` derived from `display_name` if omitted), `GET /users/{id}`, `PATCH /users/{id}` (display_name/email), `DELETE /users/{id}`
- A `user` has `source`: `app` (household, has a token), `manual` (added in-app), `splitwise` (imported member). `splits.user_identifier` joins to `users.identifier` (directory, not a hard FK).

**Group membership**
- `GET /groups/{id}/members`, `POST /groups/{id}/members` `{user_identifier}`, `DELETE /groups/{id}/members/{user_identifier}`. Splitwise import populates members + the users directory automatically.

**Balances**
- `GET /balances` (overall, archived groups excluded) and `GET /groups/{id}/balances` → per-user `{identifier, display_name, paid_total, owed_total, net}` (net>0 = owed to them).

**Categories**
- `GET /categories` → the canonical taxonomy list for pickers.

All 37 endpoints:

**Groups**
- `POST /groups` — create self-hosted group `{name}`
- `GET /groups?backend_type=&include_archived=&include_hidden=` — list (defaults exclude archived + hidden)
- `GET /groups/{id}`
- `PATCH /groups/{id}` — `{name?, hidden?}`
- `DELETE /groups/{id}` — archive (soft-delete); self-hosted only (409 for Splitwise groups)

**Expenses**
- `POST /expenses` — create with nested `splits` (and optional `items`); `{group_id, description, amount, currency?, date, category?, transaction_id?, splits[], items[]}`
- `GET /expenses?group_id=&since=&until=&include_archived=&limit=&offset=`
- `GET /expenses/{id}` — full detail: splits + items + receipts
- `PATCH /expenses/{id}` — partial; supplying `splits`/`items` replaces that set wholesale. For a Splitwise-linked expense this also pushes the edit to Splitwise (two-way sync).
- `DELETE /expenses/{id}?propagate=` — soft-delete semantics:
  - local-only expense → **archives** (sets `archived_at`) by default
  - Splitwise-linked in an **active** group → **propagates** the delete to Splitwise (so balances stay in parity); `?propagate=false` archives locally instead
  - Splitwise-linked in an **archived** group → archives locally; `?propagate=true` forces propagation
  - archived expenses drop out of `GET /expenses` (use `include_archived=true`) and out of balances; `GET /expenses/{id}` still returns them. `ExpenseResponse` carries `archived_at`.
- Split balance rule (server-enforced for self-hosted groups only; Splitwise groups defer to Splitwise): `sum(paid_share) == amount` and `sum(owed_share) == amount` within ±0.01, else 422.
- Creating/editing/deleting an expense in a Splitwise-linked group propagates to Splitwise; surface 409 (no Splitwise token — send Matt to `/auth/splitwise/login`), 422 (a participant has no Splitwise user id), 502 (Splitwise rejected it).

**Receipts** (bytes proxied through the API — the app never reaches MinIO and never holds storage credentials)
- `POST /expenses/{id}/receipts` — request body is the **raw image bytes** (`application/octet-stream`; set `Content-Type` to the real image type, e.g. `image/jpeg`). One call: the API stores the object and returns the `ReceiptResponse` (201). 404 if the expense doesn't exist, 400 on an empty body.
- `GET /expenses/{id}/receipts` — list
- `GET /receipts/{id}/content` — returns the **raw bytes** with the stored `Content-Type` (load straight into a `UIImage`)
- `DELETE /receipts/{id}`
- **⚠️ Rework needed (Mac):** the existing `ReceiptRepository.swift` is built on the old presigned flow (`upload-url` → direct `PUT` to MinIO → `register`, and `download-url`). Replace `upload(...)` with a single binary `POST` (`body: .binary(HTTPBody(imageData))` against the regenerated `upload_receipt` operation) and replace `downloadURL(...) -> URL` with a byte fetch from `download_receipt` (`/receipts/{id}/content`). Callers in `ReceiptViews` shift from "a URL to load" to "image bytes." The old `UploadUrlResponse`/`DownloadUrlResponse` schemas no longer exist in the contract.

**Plaid & accounts/transactions**
- `POST /plaid/link-token` — `{user_identifier?}` → `{link_token}` for the Plaid Link SDK
- `POST /plaid/exchange` — `{public_token, user_identifier?, institution_name?}` → item + accounts
- `POST /plaid/sync` — `{item_id?}` → sync stats
- `GET /plaid/items`, `DELETE /plaid/items/{id}` — list/unlink linked banks (unlink cascades accounts; transactions keep with null account)
- `GET /accounts`, `POST /accounts` (manual), `DELETE /accounts/{id}`
- `GET /transactions?account_id=&since=&until=&limit=&offset=`, `GET /transactions/{id}`, `POST /transactions` (manual, source=manual), `DELETE /transactions/{id}`

**Splitwise**
- `GET /auth/splitwise/login?user=` — 307 redirect to Splitwise (open in a web view / Safari); `GET /auth/splitwise/callback` — backend handles
- `GET /splitwise/status` → `{connected, users:[…]}`
- `POST /splitwise/import` → `{since?, until?, as_user?, dry_run?}` — **one-time backfill** with the stored token. Not for refreshes.
- **Scoped pull-to-refresh sync** (the steady-state path; each returns `SyncResult` counts):
  - `POST /splitwise/sync/expenses` → Expenses-tab pull-to-refresh. **Incremental** (delta-only since a server-side cursor); body `{as_user?, since?, dry_run?}`, `since` optional override. Catches edits/settle-ups and archives expenses Splitwise deleted. This is the common refresh — cheap.
  - `POST /splitwise/sync/groups` → Groups-tab pull-to-refresh (group metadata + members).
  - `POST /splitwise/sync/users` → People-tab pull-to-refresh (users directory + current user). Overlaps with `sync/groups` (both read `getGroups`); the People tab can call `sync/groups` instead if you'd rather avoid a duplicate call.
  - Balances need no client change: `/balances` + `/groups/{id}/balances` are computed from synced expenses, so they reflect whatever the last `sync/expenses` pulled. **Don't** call `/import` on refresh.
- `POST /splitwise/groups/{group_id}/import-local` → `{name?}` clones a Splitwise-linked group into a NEW self-hosted group (native copies of active expenses + splits/items + members) and archives the source so balances don't double-count. 400 if the source isn't a Splitwise group. (There is no manual per-expense push endpoint — pushes happen automatically on create/update/delete, see Expenses.)

**Health:** `GET /health`, `GET /health/db`, `GET /`.

## Data model — Postgres → SwiftData

Mirror these 9 tables as SwiftData `@Model` classes. Field names are the API/JSON names; use Swift camelCase with `CodingKeys` (or rely on the generated OpenAPI types for transport and map into SwiftData). Decision flagged below on Decimal storage.

- **Group**: `id: UUID`, `name: String`, `backendType: BackendType` (`self_hosted` | `splitwise`), `splitwiseGroupId: String?`, `hidden: Bool`, `archivedAt: Date?`, `createdAt: Date`, `updatedAt: Date`
- **Account**: `id`, `name`, `type: String?`, `plaidAccountId: String?`, `plaidItemId: UUID?`, `balance: Decimal`, `currency: String`, timestamps
- **Transaction**: `id`, `accountId: UUID?`, `plaidTransactionId: String?`, `source: TransactionSource` (`plaid` | `manual`), `description: String`, `amount: Decimal`, `currency: String`, `date: Date`, `category: String?`, `pending: Bool`, timestamps
- **Expense**: `id`, `groupId: UUID`, `transactionId: UUID?`, `splitwiseExpenseId: String?`, `description`, `amount: Decimal`, `currency`, `date: Date`, `category: String?`, `archivedAt: Date?` (soft-delete marker), timestamps; relationships → `splits`, `items`, `receipts`
- **ExpenseItem**: `id`, `name`, `quantity: Decimal`, `price: Decimal`, `category: String?`
- **Split**: `id`, `userIdentifier: String`, `paidShare: Decimal`, `owedShare: Decimal`
- **Receipt**: `id`, `bucket: String`, `objectKey: String`, `contentType: String?`
- **User**: `id`, `identifier: String` (unique; joins to `Split.userIdentifier`), `displayName: String`, `source: UserSource` (`app` | `manual` | `splitwise`), `splitwiseUserId: String?`, `email: String?`, timestamps
- **GroupMember**: `id`, `groupId: UUID`, `userIdentifier: String` (unique per group)

Money fields are `NUMERIC(12,2)` server-side. Note: SwiftData's support for `Decimal` as a stored attribute has been historically rough — if it misbehaves, store minor units as `Int` (cents) or a `String`, and convert at the boundary. Confirm during plan mode.

## Architecture

- **Transport:** swift-openapi-generator produces a typed client from `ios/openapi.json` at build time (so it always tracks the backend). Use `swift-openapi-urlsession` as the transport.
- **Persistence:** SwiftData models above; the server is authoritative, SwiftData is a cache.
- **Repository/sync layer:** repositories wrap the generated client and reconcile responses into SwiftData (upsert by `id`; respect the dedupe keys `plaidTransactionId` / `splitwiseExpenseId`). Pull-to-refresh and on-launch sync; offline reads from cache.
- **Config:** base URL + auth (if any) injected, not hardcoded.

### Incremental sync
The cacheable list endpoints (`/expenses`, `/transactions`, `/groups`, `/accounts`, `/users`) accept an **`updated_since`** (ISO-8601 datetime) query param that filters on the row's `updated_at`. The repository should persist a per-collection "last synced at" and pass it on the next pull to fetch only changes. **Caveat:** `updated_since` returns creates/updates but **not deletes** — a removed row simply stops appearing. To drop locally-cached rows the server no longer has, periodically (e.g. on a full refresh) fetch the collection without `updated_since` and delete local rows whose `id` is absent. A tombstones endpoint can be added later if this reconcile proves too heavy.

### Settle-ups and the "hide before last settle-up" view
There is no settlement endpoint by design. A settle-up is just an expense with `category == "Settle-up"` whose splits offset the balance (the debtor's `paid_share` and the creditor's `owed_share` equal the amount). Recording a payment = `POST /expenses` with those splits. The Splitwise-style "collapse expenses before the last settle-up" is a **client-side presentation** concern: find the most recent `Settle-up` expense in a group and collapse older ones. Our `GET /expenses` is date-descending + paginated, so the post-settle-up expenses arrive first naturally.

## Phase plan (build + verify after each)

**Phase 1 — Data + networking foundation** (recommended starting scope)
- New Xcode project (SwiftUI app, iOS target per decision below) inside `ios/`.
- Add swift-openapi-generator + swift-openapi-runtime + swift-openapi-urlsession via SPM; wire the generator plugin against `ios/openapi.json`.
- SwiftData `@Model` classes for the 9 tables + the enums (`BackendType`, `TransactionSource`, `UserSource`).
- Repository layer + a mapping unit test target (transport types → SwiftData). This is the verifiable core: project builds, generated client compiles, mapping tests pass on the simulator.

**Phase 2 — Core SwiftUI**
- Groups list (respecting hidden/archived + `backend_type` badge), expense list with filters, expense detail (splits/items/receipts), create/edit expense with split entry and the ±0.01 balance check mirrored client-side for fast feedback.

**Phase 3 — Receipts**
- Capture (VisionKit document scanner / PhotosPicker), `POST` the image bytes to `/expenses/{id}/receipts` in one call, list, and render receipts by fetching `/receipts/{id}/content`.

**Phase 4 — AI receipt scanning** (the headline feature)
- VisionKit/Vision OCR for text, then Apple's Foundation Models framework with an `@Generable` struct to extract `{merchant, date, line items[name, qty, price, category], total}` fully on-device. Prefill a new expense from the extraction; let Matt confirm/adjust before `POST /expenses`.

**Phase 5 — Plaid + Splitwise touchpoints**
- Plaid Link SDK flow → `POST /plaid/exchange`; transaction-to-expense picker (`GET /transactions` → prefill `POST /expenses` with `transaction_id`). Trigger Splitwise login (web view) and surface import status.

## Verification expectations

- After each phase: build for an iOS simulator and run; exercise the new surface. For Phase 1, the bar is "project builds, generated client compiles, mapping unit tests green."
- Point the app at a reachable backend. Matt can run the backend locally via `docker compose up` in the repo root (API on `:8000`), or expose it via the Cloudflare tunnel. Note: a simulator reaches a host-local backend at `http://localhost:8000`; a physical device needs the tunnel hostname or the Mac's LAN IP.
- The backend's split-balance and self-hosted-only-archive rules are authoritative — the app should handle 422/409 responses gracefully, not just prevent them client-side.

## Open decisions for Claude to confirm with Matt (plan mode)

1. **Starting scope** — default: Phase 1 only (data + networking foundation), then stop for review. Alternatives: full vertical slice through Phase 2, or API-client package only.
2. **Deployment target** — default: **iOS 26+** to enable the Foundation Models `@Generable` receipt extraction in the plan. Alternative: iOS 18+ for broader device support, but the on-device AI extraction path would need rethinking.
3. **Decimal storage** in SwiftData — default: try `Decimal`; fall back to integer cents if SwiftData balks.
4. **Project layout** — default: Xcode app project under `ios/`, with the generated API client either in-target or as a local SPM package `ios/SplitBackAPI`.
5. **Auth** — real sign-in now exists: **Apple / Google / Splitwise → a backend-issued JWT** (see the "Auth / sign-in" endpoints above). The app signs in via one provider, receives our `{token, user}` (or the `splitback://auth?token=` redirect for Splitwise), stores the JWT in the Keychain, and injects `Authorization: Bearer <jwt>` via the generated client's middleware/transport (the existing `AuthMiddleware` already reads the Keychain per request). Enforcement stays **default-open** (`AUTH_REQUIRED=false`), so early iOS development still needs no token — but wiring the sign-in flow + token storage is now Phase-appropriate. The legacy `API_TOKENS` map still works as an alternate bearer. **iOS to build:** a sign-in screen (ASAuthorizationController for Apple, GoogleSignIn SDK, `ASWebAuthenticationSession` for Splitwise catching the `splitback://auth` callback), persist the JWT, and gate the app on it when `AUTH_REQUIRED` is on.

## Onboarding / join link (iOS to build)

A shared link installs the app and pre-fills the backend endpoint. **The backend serves the join site
itself** (single host — no separate static host): `https://<public-host>/join` (e.g.
`https://splitback.app/join?name=<label>`). The endpoint defaults to the host serving the page; `?api=`
overrides it.

- **Associated domain + scheme:** add `applinks:<public-host>` (e.g. `applinks:splitback.app`) to
  `SplitBack.entitlements` (and `ios/project.yml`) — it must match the host serving the AASA. The
  `splitback://` URL scheme already exists (Splitwise OAuth) — extend it to also handle
  `splitback://configure?api=…&name=…`. The backend serves the AASA at
  `GET /.well-known/apple-app-site-association` as `application/json`, built from `APPLE_TEAM_ID` (set in
  `.env`) + bundle id `com.splitback.app`. For dev, append `?mode=developer` to the associated domain to
  bypass Apple's AASA CDN cache.
- **Configure handler** (Universal Link `https://splitback.app/join?api=` **and**
  `splitback://configure?api=`): parse `api` (+ `name`); require **https** (reject http except
  localhost); `GET <api>/server-info` → `{app, version, name, requires_auth, auth_providers}` to verify
  it's a real SplitBack backend; show a **confirm screen** ("Connect to SplitBack at `<host>`?"); then
  call the existing `AppEnvironment.setBaseURL` / `APIConfig.setOverride`. Friendly error on failure.
- **Scan invite:** an entry that reuses the VisionKit scanner (already used for receipts) to read the
  invite **QR** (encodes `splitback://configure?api=…`) and runs the same confirm flow — covers the
  "installed after tapping the link" case where the Universal Link won't re-fire.
- `/server-info` is **unguarded** (no token needed) — it's how the app validates a server before adopting
  it, and before the user has signed in.

## Reference artifacts

- `ios/openapi.json` — the API contract (regenerate from a running backend with `curl localhost:8000/openapi.json` if the backend changes).
- `PLAN.md` — product plan and rationale.
- `backend/app/models/` — the authoritative schema (source for the SwiftData mirror).
- `backend/app/schemas/` — the Pydantic request/response shapes (mirror of the OpenAPI components).
