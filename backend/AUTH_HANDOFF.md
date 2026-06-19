# SplitBack Backend — Handoff: real auth (Apple / Google / Splitwise → JWT sessions)

Briefs a Claude Code instance (or Matt) on the Linux box with Docker to add a **real authentication +
self-registration system** to the backend. Self-contained: the investigation, decisions, and file
pointers were gathered on Matt's Mac. Per the workspace CLAUDE.md convention this refers to **Matt**
(human) and **Claude** (assistant) and avoids pronouns. The approved cross-cutting plan (iOS + backend)
is at `~/.claude/plans/inherited-wobbling-aurora.md`; this file is the backend half.

## How Claude should start
1. Read this whole document. Skim `app/auth.py`, `app/routers/users.py` (`/me`, `_slugify`),
   `app/models/user.py`, `app/routers/splitwise_auth.py`, `app/integrations/splitwise/{oauth,client}.py`,
   `app/config.py`, and `migrations/versions/0006_expense_archive.py` (latest head).
2. Bring the stack up: `docker compose up -d --build`; `curl localhost:8000/health`.
3. Work the workstreams in order; `docker compose exec api pytest -q` after each. Minimal surgical
   edits, match existing patterns, no speculative abstractions.

## Why
SplitBack has **no real auth**: `app/auth.py:require_auth` is default-open and only consults a static
`api_tokens` map (`config.py`). "Users" are `/users` rows with no login. Goal: make SplitBack
self-hostable + multi-user — an operator shares the API base URL and people **self-register by signing
in with Apple, Google, or Splitwise** (email captured from the provider). This also makes "who is the
caller?" real (drives the iOS app's current-user, replacing a would-be hardcoded `matt`).

## Decisions (confirmed by Matt)
- **All three providers**: Apple, Google, Splitwise.
- The backend **verifies the provider token, find-or-creates/links the `User`, and issues its OWN
  stateless JWT** (HS256). The app stores it and sends `Authorization: Bearer <jwt>`.
- **`auth_required` flag, default false** — keeps dev/tests/open-mode working; flip to enforce. The
  static `api_tokens` map stays for back-compat.
- Email **capture** only (from the providers). Email+password, refresh tokens, and member-profile
  enrichment are **deferred/optional**.

## Workstream 1 — deps + config
- `backend/pyproject.toml`: add `pyjwt[crypto]` (sign HS256 + verify Apple/Google RS256). Reuse
  `requests` (already pulled in by `integrations/splitwise/oauth.py`) for JWKS fetches, or add `httpx`.
- `app/config.py`: add
  - `auth_jwt_secret: str = ""` (HS256 signing secret — generate a long random value in `.env`)
  - `auth_required: bool = False`
  - `google_client_id: str = ""` (the iOS OAuth client id — token `aud`)
  - `apple_audience: str = ""` (the iOS app **bundle id**, e.g. `com.splitback.app` — token `aud`)
  Keep `api_tokens`. Update `.env.example`.

## Workstream 2 — identity model (migration `0007_user_auth`)
- Add to `app/models/user.py`: `apple_sub: str | None` (unique), `google_sub: str | None` (unique),
  `avatar_url: str | None`. (`email` already exists.) Follow the column style there.
- New hand-written migration `migrations/versions/0007_user_auth.py`:
  `revision="0007_user_auth"`, `down_revision="0006_expense_archive"`; `add_column` the three +
  unique constraints on `apple_sub`, `google_sub`. Verify `upgrade`/`downgrade`.

## Workstream 3 — JWT sessions (`app/auth/tokens.py`)
- `issue(user: User) -> str`: PyJWT HS256 with `settings.auth_jwt_secret`; claims `sub=str(user.id)`,
  `identifier=user.identifier`, `iat`, `exp` (≈90 days). 
- `verify(token: str) -> uuid.UUID | None`: decode/validate; return `user.id` or `None`.
- (No session table — stateless. Mass-revoke = rotate the secret. Refresh tokens deferred.)

## Workstream 4 — provider verification (`app/integrations/auth/`)
Pure-ish modules with a cached JWKS fetch; run network in `asyncio.to_thread` from async callers.
- `apple.py` `verify_identity_token(token) -> dict`: fetch+cache `https://appleid.apple.com/auth/keys`;
  PyJWT verify RS256 with `iss="https://appleid.apple.com"`, `aud=settings.apple_audience`, exp.
  Return `{sub, email}` (Apple sends email/name only on first consent → name comes from the request).
- `google.py` `verify_id_token(token) -> dict`: fetch+cache
  `https://www.googleapis.com/oauth2/v3/certs`; verify with `iss in {accounts.google.com,
  https://accounts.google.com}`, `aud=settings.google_client_id`, exp. Return `{sub, email, name, picture}`.
- Splitwise: add `get_current_user(client) -> dict` to `integrations/splitwise/client.py`
  (SDK `client.getCurrentUser()` → `{splitwise_id, first_name, last_name, email, picture}`), normalized
  like the existing `_normalize_*` helpers.

## Workstream 5 — find-or-create + link (`app/auth/identity.py`)
`async def resolve_user(session, *, provider, sub, email, name, avatar) -> User`:
1. find by the provider's sub column (`apple_sub`/`google_sub`/`splitwise_user_id`);
2. else find by `email` and **link** the provider onto that user (set the sub, backfill avatar/name);
3. else **create** `source=UserSource.app` with a unique `identifier` (reuse the `_slugify` logic from
   `routers/users.py` — extract it to a shared util so both call it), `display_name=name or email`,
   `email`, `avatar_url`, and the provider sub.
Idempotent; commit and return the `User`.

## Workstream 6 — endpoints (`app/routers/auth.py`, mounted UNGUARDED in `main.py`)
Schemas in `app/schemas/auth.py` (`AppleAuthRequest{identity_token, full_name?}`,
`GoogleAuthRequest{id_token}`, `AuthResponse{token, user: UserResponse}`).
- `POST /auth/apple`: verify → `resolve_user(provider="apple", …, name=full_name)` → `tokens.issue` →
  `AuthResponse`. Map verify failures → **401**.
- `POST /auth/google`: same with the Google verifier.
- **Splitwise:** keep `/auth/splitwise/login`; in `/auth/splitwise/callback`
  (`routers/splitwise_auth.py`), after storing the `SplitwiseToken`, call `get_current_user`,
  `resolve_user(provider="splitwise", …)`, `tokens.issue`, then **`RedirectResponse("splitback://auth?token="+jwt)`**
  (custom scheme the iOS app catches via `ASWebAuthenticationSession`) instead of returning JSON.
- `GET /me`: already returns the `User`; add `avatar_url` to `UserResponse`/`MeResponse`
  (`app/schemas/user.py`).

## Workstream 7 — enforce (`app/auth.py` rewrite)
Keep `require_auth(...) -> str | None` (downstream unchanged): if a bearer is present, try
`tokens.verify` → load the `User` → return `identifier`; else try the `api_tokens` map; else
`None` when `not settings.auth_required`, or **raise 401** when `auth_required`. (Health + the Splitwise
login/callback stay unguarded; `/auth/*` are unguarded.)

## Workstream 8 — tests (`backend/tests/`)
- `tokens.issue`→`verify` round-trip (and reject tampered/expired).
- `resolve_user`: new user; existing-by-sub; **link-by-email** (same email, second provider → one user,
  both subs set).
- `/auth/apple` + `/auth/google` with the provider verifier **mocked** (no live JWKS in tests) →
  returns a token + user; bad token → 401.
- `require_auth` accepts an issued JWT (identity resolves) and 401s on a bad token when
  `auth_required=true`; passes through when false.
- Migration `upgrade`/`downgrade`.

## Then: regenerate the iOS contract
With the stack running:
```
curl -s localhost:8000/openapi.json > ios/openapi.json
python3 ios/scripts/prepare_openapi.py ios/openapi.json ios/SplitBackAPI/Sources/SplitBackAPI/openapi.json
```
New `auth_*` ops + `avatar_url` appear for the iOS client (Part B). Do not hand-edit the copy.

## Config / prerequisites Matt provides
- `AUTH_JWT_SECRET` — generate (e.g. `openssl rand -hex 32`).
- `APPLE_AUDIENCE` = the iOS bundle id (`com.splitback.app`). Native token verification needs no Apple
  secret.
- `GOOGLE_CLIENT_ID` = the Google Cloud OAuth **iOS client id** (token audience).
- Splitwise consumer key/secret + redirect URI already set.

## Out of scope (deferred)
Email+password sign-in, refresh tokens / server-side session revocation, Splitwise member-profile
enrichment (emails/avatars for non-app users — nice-to-have in `integrations/splitwise/importer.py`).

## Reference
- Patterns to copy: router `app/routers/groups.py`; schema `app/schemas/group.py`; model column style
  `app/models/user.py`; OAuth/`requests` use `app/integrations/splitwise/oauth.py`; `_slugify` +
  `/me` in `app/routers/users.py`; migration style `migrations/versions/0006_expense_archive.py`.
- iOS half: `~/.claude/plans/inherited-wobbling-aurora.md` Part B (AuthService, AuthGateView, session).
