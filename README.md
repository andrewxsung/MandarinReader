# MandarinReader

A personalized Traditional Chinese immersion tracker that learns from your real-world exposure. Instead of generic HSK word lists, it builds a personal frequency corpus from text you actually encounter, then prioritizes flashcards accordingly.

## Concept

The core insight: existing apps (Pleco, Anki, PinyinOCR) handle individual pieces well, but none close the loop between **what you encounter in the wild** and **what you should study next**. MandarinReader does exactly that.

Every word you see gets logged with:
- **Encounter count** — how many times you've seen it across all inputs
- **Source diversity** — seen on websites, menus, AND camera roll = higher priority
- **Familiarity** — unknown / learning / known, updated via SRS review

Priority score: `(encounter_count × source_diversity_count) / familiarity_score`
Unknown words use `0.5` as the denominator so they float to the top.

### Input Sources
- **Chrome extension** — captures any Chinese-language page you visit; the backend extracts its vocabulary via Claude AI
- **Manual paste** — fallback for WeChat messages, emails, etc.
- **Camera / photo** *(planned)* — OCR screenshots, menus, signs via Apple Vision
- **Share sheet** *(planned)* — iOS share sheet from any app

### Learning Interface
- Flashcard deck auto-generated from top unknown words, sorted by priority score
- Spaced repetition (custom SM-2 implementation) so known words fade out of rotation
- In-context review — shows the original sentence the word was captured from
- Mark as **known** / **learning** / **ignore** to tune the queue
- AI-generated daily study plan (Claude Haiku selects the 10–15 most valuable words)
- Stroke-order animations via `hanzi-writer` for writing practice

---

## Architecture

| Layer | Tech |
|---|---|
| Backend | FastAPI 0.115 + PostgreSQL 16 + SQLAlchemy async (asyncpg) |
| Chrome Extension | Vanilla JS, Manifest V3 (no bundler) |
| Dictionary | CC-CEDICT (~115k entries, imported once) |
| AI | Claude Haiku (`claude-haiku-4-5-20251001`) for page analysis + study planning |
| SRS | Custom SM-2 in `backend/app/services/srs.py` |
| Hosting | Railway (backend + Postgres) — `https://mandarinreader-production.up.railway.app` |

### Database Tables
| Table | Purpose |
|---|---|
| `cedict` | CC-CEDICT reference (~115k entries, read-only after import) |
| `users` | Accounts (email + argon2id password hash) |
| `sessions` | Bearer-token sessions (SHA-256 of the token, 30-day sliding expiry) |
| `words` | Per-user vocabulary corpus (one row per user per unique Traditional word) |
| `encounters` | Append-only log of every word sighting (source, context sentence) |
| `pages` | Per-user log of pages analyzed by the extension |

### familiarity_score values
- `-1` = ignored (removed from queue)
- `0` = unknown
- `1` = learning (in SRS rotation)
- `2` = known (periodic refreshes only)

---

## Repository Structure

```
MandarinReader/
├── backend/
│   ├── app/
│   │   ├── main.py              # FastAPI app, CORS, router wiring, validation errors
│   │   ├── auth.py              # Bearer-session auth dependency (get_current_user)
│   │   ├── database.py          # Async SQLAlchemy engine + session
│   │   ├── models.py            # ORM models
│   │   ├── schemas.py           # Pydantic request/response schemas
│   │   ├── crud.py              # Core upsert + priority logic (most critical)
│   │   ├── routers/
│   │   │   ├── auth.py          # POST /api/auth/signup|login|logout, GET /api/auth/me
│   │   │   ├── ingest.py        # POST /api/ingest (server-side Claude analysis, 50/day)
│   │   │   ├── queue.py         # GET /api/queue
│   │   │   ├── review.py        # POST /api/review/{word_id}
│   │   │   ├── words.py         # GET /api/words, /api/word/{word}, /api/recent
│   │   │   └── study.py         # GET /api/study/plan, /api/study/free
│   │   └── services/
│   │       ├── claude.py        # Claude Haiku page analysis (server-side)
│   │       ├── security.py      # argon2id password hashing + token helpers
│   │       ├── srs.py           # SM-2 spaced repetition
│   │       ├── cedict.py        # CC-CEDICT parser + DB lookup
│   │       └── priority.py      # Priority score formula
│   ├── migrations/
│   │   ├── 001_initial_schema.sql   # Full DB schema — run first
│   │   ├── 002_load_cedict.py       # One-time CEDICT import script
│   │   └── 003_users_auth.sql       # Accounts + per-user scoping (wipes vocabulary)
│   ├── static/
│   │   └── index.html           # Frontend dashboard (served at /) — no auth yet, see below
│   ├── Dockerfile
│   └── requirements.txt
├── extension/
│   ├── manifest.json            # MV3 manifest
│   ├── config.js                # BACKEND_URL — the only place the backend origin appears
│   ├── background.js            # Service worker: extracts page text, POSTs it to /api/ingest
│   └── popup.html / popup.js    # Popup: sign in / create account, capture, sign out
└── ios/MandarinReader/          # iPadOS handwriting practice app (see iPadOS App section)
```

---

## API Endpoints

All `/api/*` endpoints except signup, login and logout (a no-op without a token) require an `Authorization: Bearer <token>` header; every user only sees their own vocabulary. `/health` is always public.

| Method | Path | Description |
|---|---|---|
| `GET` | `/health` | Health check |
| `POST` | `/api/auth/signup` | Create account — body `{email, password}` (password ≥ 8 chars) → `201 {token, email}` |
| `POST` | `/api/auth/login` | Log in — body `{email, password}` → `{token, email}` |
| `POST` | `/api/auth/logout` | Revoke the current bearer token → `204` |
| `GET` | `/api/auth/me` | Current user → `{email}` |
| `POST` | `/api/ingest` | Analyze page text with Claude server-side and store its vocabulary (50 captures/user/day) |
| `GET` | `/api/queue?n=20` | Flashcard queue sorted by priority score |
| `POST` | `/api/review/{word_id}` | Submit review result (`known`/`learning`/`ignore`) |
| `GET` | `/api/words` | All words with stats (paginated) |
| `GET` | `/api/word/{word}` | Single word lookup (corpus + CEDICT fallback) |
| `GET` | `/api/recent` | Top words from last 2 captured pages |
| `GET` | `/api/study/plan` | AI-generated daily study plan (Claude Haiku) |
| `GET` | `/api/study/free` | Free study — known + learning word decks |

### Ingest request shape
Requires `Authorization: Bearer <token>`. The backend calls Claude itself — clients never hold an Anthropic key.
```json
{
  "url": "https://...",
  "title": "Page title",
  "page_text": "visible page text (10–8000 chars)"
}
```
Returns `{words_added, words_updated, page_id, page_purpose, total_words}`. Errors: `401` no/invalid token, `422` bad body, `429` daily limit reached, `502` Claude analysis failed (including no `ANTHROPIC_API_KEY` configured).

### Known limitation
The static web dashboard (`backend/static/index.html`) predates accounts and does not yet send auth headers, so its API calls get `401` against this backend.

---

## Local Development Setup

### Prerequisites
- Python 3.12+
- PostgreSQL running locally
- CC-CEDICT file from [mdbg.net](https://www.mdbg.net/chinese/dictionary?page=cedict)

### Backend
```bash
(cd backend && pip install -r requirements.txt)

createdb mandarinreader
psql mandarinreader < backend/migrations/001_initial_schema.sql

# Place cedict_ts.u8 at backend/data/cedict_ts.u8
(cd backend && python migrations/002_load_cedict.py)

# Accounts + per-user scoping. Run once; it deliberately fails on a re-run.
psql -v ON_ERROR_STOP=1 mandarinreader < backend/migrations/003_users_auth.sql

cd backend
ANTHROPIC_API_KEY=sk-ant-... uvicorn app.main:app --reload
```

`ANTHROPIC_API_KEY` is required by the **backend only** — page analysis runs server-side. Without it, signup/login/queue/review all work, but `POST /api/ingest` returns `502`.

### Chrome Extension
1. `chrome://extensions` → Enable Developer Mode → Load unpacked → select `extension/`
2. Click the extension icon → **Create one** to make an account (or sign in)

There is no options page and nothing to configure: the backend origin is the `BACKEND_URL` constant in `extension/config.js`, which defaults to `http://localhost:8000`. For a release build, flip it to `https://mandarinreader-production.up.railway.app` (the production value is in the file's comment) and reload the extension.

### Environment Variables (`.env` in `backend/`)
```
DATABASE_URL=postgresql+asyncpg://localhost/mandarinreader
ANTHROPIC_API_KEY=sk-ant-...   # backend-only; required for /api/ingest
CORS_ORIGINS=*
```

### Running Tests
Backend (needs a local Postgres; tests never call Anthropic):
```bash
pip install -r backend/requirements-dev.txt
createdb mandarinreader_test
cd backend && pytest
```

iOS (from the repo root):
```bash
xcodebuild test -project ios/MandarinReader/MandarinReader.xcodeproj -scheme MandarinReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MandarinReaderTests
```

---

## Cloud Deployment (Railway)

- **Backend URL:** `https://mandarinreader-production.up.railway.app`
- **Platform:** Railway hobby plan (~$5–7/mo, Postgres included)
- **Auth:** email/password accounts; `Authorization: Bearer <token>` required on all `/api/*` routes except signup/login/logout
- **Dockerfile:** `backend/Dockerfile` — `python:3.12-slim`, uvicorn on port 8000

Railway env vars to set: `DATABASE_URL` (auto-provided), `ANTHROPIC_API_KEY`, `CORS_ORIGINS`, `PORT=8000`. (`MANDARINREADER_API_KEY` is no longer used — delete it from the Railway service.)

After provisioning a new Railway Postgres instance, run migrations:
```bash
psql "$RAILWAY_DATABASE_URL" < backend/migrations/001_initial_schema.sql
psql "$RAILWAY_DATABASE_URL" -c "ALTER TABLE cedict ADD CONSTRAINT cedict_traditional_pinyin_unique UNIQUE (traditional, pinyin);"
DATABASE_URL="$RAILWAY_DATABASE_URL" python backend/migrations/002_load_cedict.py
psql -v ON_ERROR_STOP=1 "$RAILWAY_DATABASE_URL" < backend/migrations/003_users_auth.sql   # accounts; see below
```

**Accounts migration (003).** Run once against the Railway DB when rolling out accounts:
```bash
psql -v ON_ERROR_STOP=1 "$RAILWAY_DATABASE_URL" < backend/migrations/003_users_auth.sql
```
This is **destructive to existing vocabulary by design** — it truncates `words`, `encounters`, and `pages` (start-fresh decision; `cedict` is untouched). Run it right after deploying the new code: the vocabulary routes error until `words.user_id` exists, and the old code breaks once it does. It tolerates the new app having already created the `users`/`sessions` tables at startup, and it refuses to run a second time, so the wipe can't repeat.

---

## Extension Flow

1. User signs in (or creates an account) in the popup → `POST /api/auth/login|signup`; the bearer token and email are stored in `chrome.storage.local`
2. User clicks "Capture This Page" → `popup.js` → `sendMessage` → `background.js`
3. `background.js` runs `executeScript` on the active tab to extract visible text (8000 char limit)
4. `POST /api/ingest` with `Authorization: Bearer <token>` and `{url, title, page_text}`
5. The backend calls Claude (Haiku, temp=0, max_tokens=2500, 25s timeout) to extract page purpose + key vocabulary and stores the words — the extension never holds an Anthropic key
6. Result stored in `chrome.storage.local`, displayed in popup. A `401` clears the stored token and returns the popup to the sign-in form

**Permissions:** `activeTab`, `storage`, `scripting`, plus host permissions for exactly two origins — `http://localhost:8000/*` and `https://mandarinreader-production.up.railway.app/*` — so the service worker can reach whichever backend `config.js` points at.

### Known Gotchas
- MV3 service workers are ephemeral — all state in `chrome.storage`, never module-level vars
- If you point `config.js` at any other backend origin, add it to `host_permissions` in `manifest.json` too
- `executeScript` fails on `chrome://`, `file://`, PDF tabs — caught with try/catch
- CC-CEDICT batch insert uses 1000 rows/batch — never row-by-row
- CJK validation (`is_cjk()` in `crud.py`) filters Claude's non-Chinese output

---

## Development Log

### 2026-03-12 — Core MVP
Full stack built and running locally. FastAPI + PostgreSQL backend with async SQLAlchemy. Schema: `cedict` (~115k CC-CEDICT entries, read-only), `words` (user corpus), `encounters` (append-only log), `pages` (analyzed pages). Custom SM-2 SRS in `backend/app/services/srs.py`. Priority formula: `(encounter_count × source_diversity_count) / familiarity_score` (unknowns use 0.5 to float to top).

Chrome MV3 extension captures page text, calls Claude Haiku for word extraction, POSTs to `/api/ingest`. All state in `chrome.storage.local`. API key + backend URL configurable via Options page.

Frontend dashboard (`/static/index.html`): vocabulary list with filter/sort, inline familiarity buttons, priority bar visualization, context sentence expansion. Flashcard review with two modes: AI-generated daily study plan (`/api/study/plan`) and Free Study (Sight Reading + "Worth Another Look" decks). Pinyin tone color-coding throughout. Optimistic UI updates with server sync rollback on error.

### 2026-03-12 — Stroke-Order Animations
Replaced freehand canvas drawing with animated stroke-order playback using `hanzi-writer` CDN library (v3.5). Flow: character strokes animate → user replays → clicks "I wrote it" → character blurs for recall → "Done Practicing" advances. Multi-character words split into individual CJK characters, each animated sequentially. Unsupported characters show graceful fallback. Phase model simplified from `trace|recall` to `watch|recall`. Only `backend/static/index.html` changed.

---

## iPadOS App

Native SwiftUI app for iPad (iPadOS 16.6+) that pulls from the priority queue and runs flash-then-recall handwriting practice sessions.

### Flow
1. **Sign in** — on launch, `LoginView` asks for email + password (or creates an account) until the user is signed in; the bearer token is stored in the Keychain, so later launches go straight to Start Session
2. **Start Session** — select word count (5–50), fetches from `GET /api/queue?n=N`
3. **Flash phase** — character shown for 3 seconds, then hidden
4. **Writing phase** — user free-writes each character stroke-by-stroke on a 米字格 canvas (finger or Apple Pencil). Each stroke is validated against Hanzi Writer stroke data; accepted strokes snap to typeset stroke shapes, rejected strokes flash red, and a hint pulses in after 3 misses on the same stroke (force-accepted after 6 so a round can't stall). Round is correct iff total misses < 20% of the word's stroke count. Words with a character missing from the dataset fall back to the iOS Chinese handwriting keyboard + exact match.
5. **3 rounds per card** — 2+ correct = known, else learning; skip = known
6. **Summary** — shows results, syncs to backend via parallel `POST /api/review/{word_id}` calls
7. **Settings** (gear icon) — shows the signed-in account and a Sign Out button; there are no backend URL or key fields. Any `401` from the API signs the user out and returns to `LoginView`

**Backend:** compile-time constant in `App/AppConfig.swift` — Debug builds talk to `http://localhost:8000` (reachable from the Simulator), Release builds to `https://mandarinreader-production.up.railway.app`.

### File Structure
```
ios/MandarinReader/MandarinReader/
├── MandarinReaderApp.swift           # Entry point: LoginView or StartSessionView, injects AuthStore
├── App/
│   ├── AppConfig.swift               # Backend base URL (Debug → localhost, Release → Railway)
│   ├── AuthStore.swift               # Observable auth state: sign in/up/out, 401 handling
│   ├── TokenStorage.swift            # Keychain token (+ email in UserDefaults); in-memory test double
│   ├── LoginView.swift               # Sign in / create account form
│   ├── LegacyCleanup.swift           # One-time removal of pre-accounts UserDefaults keys
│   └── SettingsView.swift            # Signed-in account + Sign Out
├── HanziWriterData.bundle/           # 9,574 per-character stroke JSONs (Arphic license)
├── Handwriting/
│   ├── SVGPathParser.swift           # Absolute M/L/Q/C/Z SVG path → CGPath
│   ├── StrokeData.swift              # Models + BundleStrokeDataStore (y-flip at load)
│   ├── HanziGeometry.swift           # Fréchet distance, resample, normalize (geometry.ts port)
│   ├── StrokeMatcher.swift           # Stroke acceptance checks (strokeMatches.ts port)
│   └── HandwritingQuiz.swift         # Per-word quiz state machine + grading
├── Networking/
│   ├── APIClient.swift               # Bearer-token client: signup/login/logout, fetchQueue, submitReview
│   └── Models.swift                  # WordQueueItem, PendingReview, ReviewResult
├── Session/
│   └── SessionViewModel.swift        # State machine: flash → writing → feedback → summary
└── Views/
    ├── StartSessionView.swift        # Word count picker + Start button
    ├── HandwritingCanvasView.swift   # 米字格 canvas: ink, typeset fills, hints
    ├── PracticeView.swift            # Flash + stroke canvas (or keyboard fallback) + feedback loop
    ├── FeedbackOverlay.swift         # Correct/incorrect overlay badge
    └── SummaryView.swift             # Results + parallel sync
```

### Running in the Simulator
Start the backend locally (see Local Development Setup), then run the `MandarinReader` scheme on a simulator — the Debug build talks to `http://localhost:8000`. Sign in or create an account on the login screen.

### Running on Device
1. Open `ios/MandarinReader/MandarinReader.xcodeproj` in Xcode
2. Signing & Capabilities → select your team, set a unique bundle ID
3. Enable Developer Mode on the iPad: Settings → Privacy & Security → Developer Mode (reboots device)
4. Select your iPad as destination. To use production, set the scheme's Run build configuration to **Release** (Product → Scheme → Edit Scheme → Run → Info); a Debug build on hardware can't reach `localhost`, so for a local backend change the Debug URL in `AppConfig.swift` to your Mac's LAN IP (e.g. `http://192.168.1.20:8000`). Then ⌘R
5. On iPad: Settings → General → VPN & Device Management → trust your developer profile
6. In the app: sign in or create an account — there is nothing to configure

---

## Development Log

### 2026-10-11 — Accounts + Server-Side Claude

- **Accounts:** email/password signup/login (argon2 hashes) with opaque bearer-token sessions; `Authorization: Bearer <token>` replaces the shared `X-API-Key` on all `/api/*` routes except signup/login/logout.
- **Per-user data:** `words`, `encounters`, and `pages` are scoped by `user_id`; every query filters on the signed-in user.
- **Claude moved server-side:** `POST /api/ingest` now takes raw page text and the backend calls Claude Haiku with its own `ANTHROPIC_API_KEY` (25s timeout, no retries), limited to 50 captures per user per day. The `anthropic` SDK is pinned and an offline test drives the real SDK request path through a mock HTTP transport. `/api/study/plan` shares the same async client.
- **Extension:** options page removed; the popup has a sign-in/create-account form. On install/update the worker deletes the old Claude key and backend settings from `chrome.storage.sync`.
- **iOS:** Keychain-backed sign-in replaces the manual backend URL/key settings. A one-time cleanup on first launch removes the legacy settings and any queued pre-accounts reviews.
- **Migration 003 wipes vocabulary:** `003_users_auth.sql` truncates `words`/`encounters`/`pages` and restarts their ids (start-fresh decision; `cedict` untouched). It refuses to run twice.

### 2026-07-02 — Laoshi-Style On-Screen Stroke Matching

Replaced keyboard input with free-writing on a canvas, Laoshi/Skritter style. The key insight vs. the failed April PencilKit + Vision attempt: no recognition needed at all — during review the app already knows the expected character, so each drawn stroke is matched against that character's known stroke medians.

- **Data:** vendored `hanzi-writer-data` (Make Me a Hanzi) — 9,574 per-character JSONs (~46 MB) with SVG stroke outlines + median polylines, covering Traditional. Bundled as `HanziWriterData.bundle`, a folder named `*.bundle` so Xcode 16 synchronized groups copy it as a single wrapper resource (no pbxproj surgery, no 9.5k flattened resources). Arphic Public License text ships in the bundle; attribution in Settings.
- **Matching:** native Swift port of Hanzi Writer's `strokeMatches.ts` + `geometry.ts` (avg-distance gate with halved threshold for later strokes, start/end distance, direction cosine similarity, normalized-curve Fréchet shape fit over ±π/16 rotations, length ratio, backwards-stroke detection, later-stroke leniency tightening). Coordinates pre-flipped into top-left 1024-space at load (`y' = 900 − y`) so matcher, views, and touch input share one system.
- **Quiz:** `HandwritingQuiz` plain struct (deliberately not an ObservableObject — sidesteps both Xcode 26 MainActor gotchas). Hint after 3 misses on a stroke, force-accept after 6, round correct iff misses < 20% of stroke count. One character at a time with a progress row for multi-char words.
- **Fallback:** words with any character missing from the dataset keep the old TextField + Chinese handwriting keyboard path, per card.
- Built TDD throughout: 51 new unit tests (parser, store, geometry, matcher, quiz, coordinate conversion), 97/97 suite green. Coordinate-conversion round-trip test guards the classic "everything matches / nothing matches" scaling footgun.

**Status:** simulator-verified (build, tests, app boot with bundle). Pending on-device QA with Apple Pencil: stroke feel, hint timing, multi-char flow, fallback card, skip mid-writing.

### 2026-04-19 — Bug Squash + First Device Run

Ran the app on a physical iPad end-to-end for the first time. Fixed a batch of correctness bugs surfaced by code review and the first live test.

**iPad app fixes:**
- **Flash race:** `PracticeView.task` was swallowing `CancellationError` via `try?`, so a skipped card's cancelled task would resume and advance the *next* card's flash phase prematurely. Now guards `advanceFromFlash(for:)` with the word id the task was started for.
- **Summary labels:** `PendingReview` now carries `traditional`/`pinyin` so the summary list and recovery banner render the actual character instead of `Word #id`.
- **Round-3 button text:** `"Try Again →"` showed on the final round where no retry is possible. Added `isFinalRound` derived state to label the button `"Next Word →"` on round 3.
- **Unsynced review persistence:** Reviews are now saved to `UserDefaults` via a `PendingReviewStore` protocol (swappable for tests). On app launch, if unsynced reviews are detected, `StartSessionView` shows a recovery banner with Sync/Discard actions. `SummaryView.failed` gains a "Discard & Exit" button so a permanently-failing sync can't trap the user.
- **Xcode 26 deinit crash (expanded):** The `nonisolated deinit { }` workaround isn't limited to classes declared `@MainActor` — any plain `final class` stored as a property of a `@MainActor` owner goes through the same broken back-deploy shim under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and crashes libmalloc. Applied to `UserDefaultsPendingReviewStore` and `InMemoryPendingReviewStore`.

**Backend fix:**
- **Queue excluded new words.** `get_queue` in `crud.py` filtered on `familiarity_score == 1`, so newly ingested words (fam=0) never appeared for review even though the priority scoring in `priority.py` was specifically designed to float them to the top. Changed to `familiarity_score.in_([0, 1])`.

**Status:** App runs on iPad Pro 12.9" (5th gen). Queue fetch → flash → handwriting → review → sync path confirmed working against the Railway backend.

### 2026-04-13 — iPadOS Handwriting Practice App

Built native SwiftUI iPad app on the `feat/ipad-app` branch (14 commits).

**Architecture:** `StartSessionView` → `PracticeView` → `SummaryView` flow. `SessionViewModel` manages the state machine (flash → writing → feedback, 3 rounds per card). `APIClient` handles network calls with `URLSession`. `AppSettings` persists backend config via `@Published` properties backed by `UserDefaults`.

**Key decisions:**
- Started with PencilKit canvas + Vision framework `VNRecognizeTextRequest` for on-device handwriting recognition. Vision was unreliable for isolated handwritten glyphs — replaced with iOS system Chinese handwriting keyboard input and exact string comparison. Simpler and more accurate.
- `withThrowingTaskGroup` for parallel review sync — all review results POST concurrently.
- Xcode 26 gotcha: `@MainActor final class` with deployment target < iOS 18 crashes in `swift_task_deinitOnExecutorMainActorBackDeploy` — requires explicit `nonisolated deinit { }` on every such class. (Updated 2026-04-19: applies to plain `final class` stored on MainActor owners too.)

### 2026-04-12 — Cloud Deployment + API Key Auth
- Added `X-API-Key` auth on all `/api/*` routes (skipped when env var unset for local dev).
- CORS origins configurable via `CORS_ORIGINS` env var.
- Added `backend/Dockerfile`, deployed to Railway with Postgres 16.
- Chrome extension updated with API key field in Options.

---

## Planned / Next Up

- **Remaining iPad P1s** — retry double-submit guard on sync, mid-session exit handling, force-unwrap audit
- **Camera input** — OCR photos via Apple Vision (iOS) to pipe into corpus
- **Share sheet** — Accept text/images from any iOS app
- **Known-word bootstrapping** — Import HSK lists or placement test to seed familiarity scores
- **Traditional/Simplified toggle** — Currently Traditional-only; Simplified support planned
