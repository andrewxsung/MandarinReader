# Accounts + Server-Side Claude Key — Design

**Date:** 2026-08-08
**Status:** Approved by Andrew (design review in session)

## Goals

1. Users never enter a Claude API key or backend URL. The Claude call moves server-side; the backend URL is baked into the clients.
2. Email/password accounts, with all vocabulary data scoped per user.

Deployment context: backend will be deployed publicly for real users. iOS app is in scope. No email infrastructure in v1 (no verification, no password reset). Existing single-user data is **not** migrated — start fresh.

## Non-goals (v1)

- Email verification, password reset, OAuth/social login
- Account management UI beyond signup/login/logout
- Billing or paid tiers

## Auth approach (decision)

**DB-backed opaque session tokens** (chosen over JWT and hosted auth):

- `users` table: email (lowercased, unique) + argon2id password hash
- `sessions` table: SHA-256 hash of a random 256-bit token, sliding 30-day expiry
- Clients send `Authorization: Bearer <token>`
- Simple, instantly revocable, one indexed DB lookup per request

## 1. Data model & migration

New tables:

```sql
users (
  id            serial PRIMARY KEY,
  email         text NOT NULL UNIQUE,      -- stored lowercased
  password_hash text NOT NULL,             -- argon2id
  created_at    timestamptz NOT NULL DEFAULT now()
)

sessions (
  id           serial PRIMARY KEY,
  user_id      int NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash   text NOT NULL UNIQUE,       -- sha256 hex of raw bearer token
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  last_used_at timestamptz
)
```

Changes to existing tables:

- `words.user_id` int NOT NULL FK → users; unique constraint changes from `traditional` to `(user_id, traditional)`
- `pages.user_id` int NOT NULL FK → users
- `encounters`: unchanged (reaches user via `word_id`)
- `cedict`: unchanged (shared read-only dictionary)

Migration `003_users_auth.sql`: create `users`/`sessions`, **TRUNCATE** `words`, `encounters`, `pages` (start-fresh decision), add the `user_id` columns and new constraints.

## 2. Backend API

### Auth endpoints (`app/routers/auth.py`, unauthenticated except logout)

- `POST /api/auth/signup` `{email, password}` → 201 `{token, email}`. Email normalized to lowercase; password min 8 chars; 409 if email exists. Signed in immediately.
- `POST /api/auth/login` `{email, password}` → `{token, email}`. Generic 401 "invalid email or password" on any failure.
- `POST /api/auth/logout` (Bearer) → deletes the session row.

Password hashing: **argon2id** via `argon2-cffi`. Tokens: `secrets.token_urlsafe(32)`, stored as SHA-256 hex.

### Auth dependency

`verify_auth` in `app/auth.py` is replaced: parse `Authorization: Bearer`, SHA-256 the token, look up session, reject if missing/expired (401), slide `expires_at` forward to now+30 days (throttled: only write when >1 day of drift, to avoid a write per request), return the `User`. All routers depend on it; all queries in `crud.py` filter by `user_id`.

The old `MANDARINREADER_API_KEY` shared-secret mechanism and the `X-API-Key` header are removed.

### Claude moves server-side

`POST /api/ingest` request body changes to `{url, title, page_text}` (page_text ≤ 8000 chars, enforced server-side too). The backend:

1. Checks rate limit: max **50 captures per user per day** (count of `pages` rows for the user since midnight UTC) → 429 with a clear message.
2. Calls Claude Haiku via the official `anthropic` async SDK (`AsyncAnthropic`), model `claude-haiku-4-5-20251001`, key from `ANTHROPIC_API_KEY` env var, using the same extraction prompt currently in `extension/background.js` (moved to `app/services/claude.py`).
3. Parses the JSON (strip code fences, validate shape); on Claude/parse failure → 502 `{"detail": "analysis failed"}`.
4. Runs the existing ingest/upsert logic scoped to the user.

Config via env vars: `ANTHROPIC_API_KEY` (required in prod), `DATABASE_URL`, `CORS_ORIGINS`.

## 3. Chrome extension

- **Options page deleted** (options.html/options.js removed, `options_page` removed from manifest).
- New `config.js`: `const BACKEND_URL = "..."` — a single constant, set to `http://localhost:8000` until a production domain exists, then flipped to the deployed URL (a one-line change at deploy time; no user-facing setting either way).
- **Popup**: if no token in `chrome.storage.local`, show a login/signup form (email, password, toggle link between modes). On success store `{token, email}`. Footer shows signed-in email + "sign out".
- **background.js**: delete `callClaude`, `buildPrompt`, and the Anthropic constants. Capture flow becomes: extract page text → `POST {BACKEND_URL}/api/ingest` with `Authorization: Bearer` and `{url, title, page_text}`. On 401: clear stored token; popup shows login. On 429: show the rate-limit message.
- `manifest.json` `host_permissions` narrowed to the backend origin (plus localhost for dev); the api.anthropic.com permission need is gone.

## 4. iOS app

- `APIClient`: base URL hardcoded (prod; `#if DEBUG` → `http://localhost:8000`). `X-API-Key` replaced by `Authorization: Bearer <token>`. New methods: `signup(email:password:)`, `login(email:password:)`, `logout()` returning/clearing the token.
- Token stored in the **Keychain** (small `KeychainStore` helper; not UserDefaults).
- New `LoginView` shown when no token exists; any 401 from the API clears the token and returns to login. Settings drops the API-key field and gains a signed-in-as row + sign-out button.
- Apply known Xcode 26 constraints: new `@MainActor final class`es get explicit `nonisolated deinit { }`; persistence tests read defaults/Keychain directly rather than instantiating a second ObservableObject.

## 5. Error handling

| Status | Client behavior |
|---|---|
| 401 | Clear token, show login |
| 409 (signup) | "An account with this email already exists" |
| 429 | "Daily capture limit reached — try again tomorrow" |
| 502 | "Analysis failed — try again" |

Login failures are a generic 401 to avoid user enumeration on the login path (signup necessarily reveals existing emails; accepted for v1).

## 6. Testing

Backend (pytest, mocked Claude client):
- signup → login → authenticated request happy path
- wrong password / unknown email → generic 401
- expired session → 401; logout revokes token
- **cross-user isolation**: user A's words/queue/review never visible to user B (the critical test)
- ingest: rate limit returns 429 at 51st capture; Claude failure returns 502; CJK filtering still applies

iOS: extend `APIClientTests` with `URLProtocolMock` for signup/login/logout and Bearer header assertions.

Extension: manual verification (login, capture, sign out, 401 recovery).

## Security notes

- Argon2id hashing; raw tokens never stored (SHA-256 at rest); tokens only in `chrome.storage.local` / Keychain.
- HTTPS required in production; server-held `ANTHROPIC_API_KEY` never reaches clients.
- Per-user rate limiting bounds Claude spend against abusive accounts.
- CORS restricted to the extension origin and app domains via `CORS_ORIGINS`.
