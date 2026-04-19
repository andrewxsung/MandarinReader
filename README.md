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
- **Chrome extension** — captures any Chinese-language page you visit, extracts vocabulary via Claude AI
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
| `words` | User's vocabulary corpus (one row per unique Traditional word) |
| `encounters` | Append-only log of every word sighting (source, context sentence) |
| `pages` | Log of pages analyzed by the extension |

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
│   │   ├── main.py              # FastAPI app, CORS, router wiring, auth
│   │   ├── auth.py              # API key auth dependency (X-API-Key header)
│   │   ├── database.py          # Async SQLAlchemy engine + session
│   │   ├── models.py            # ORM models
│   │   ├── schemas.py           # Pydantic request/response schemas
│   │   ├── crud.py              # Core upsert + priority logic (most critical)
│   │   ├── routers/
│   │   │   ├── ingest.py        # POST /api/ingest
│   │   │   ├── queue.py         # GET /api/queue
│   │   │   ├── review.py        # POST /api/review/{word_id}
│   │   │   ├── words.py         # GET /api/words, /api/word/{word}, /api/recent
│   │   │   └── study.py         # GET /api/study/plan, /api/study/free
│   │   └── services/
│   │       ├── srs.py           # SM-2 spaced repetition
│   │       ├── cedict.py        # CC-CEDICT parser + DB lookup
│   │       └── priority.py      # Priority score formula
│   ├── migrations/
│   │   ├── 001_initial_schema.sql   # Full DB schema — run first
│   │   └── 002_load_cedict.py       # One-time CEDICT import script
│   ├── static/
│   │   └── index.html           # Frontend dashboard (served at /)
│   ├── Dockerfile
│   └── requirements.txt
├── extension/
│   ├── manifest.json            # MV3 manifest
│   ├── background.js            # Service worker: Claude API + backend POST
│   ├── popup.html / popup.js    # Extension popup UI
│   └── options.html / options.js  # Settings: Claude key, backend URL, API key
└── ios/MandarinReader/          # iPadOS handwriting practice app (see iPadOS App section)
```

---

## API Endpoints

All `/api/*` endpoints require `X-API-Key` header (when `MANDARINREADER_API_KEY` env var is set). `/health` is always public.

| Method | Path | Description |
|---|---|---|
| `GET` | `/health` | Health check |
| `POST` | `/api/ingest` | Receive page + word list from extension |
| `GET` | `/api/queue?n=20` | Flashcard queue sorted by priority score |
| `POST` | `/api/review/{word_id}` | Submit review result (`known`/`learning`/`ignore`) |
| `GET` | `/api/words` | All words with stats (paginated) |
| `GET` | `/api/word/{word}` | Single word lookup (corpus + CEDICT fallback) |
| `GET` | `/api/recent` | Top words from last 2 captured pages |
| `GET` | `/api/study/plan` | AI-generated daily study plan (Claude Haiku) |
| `GET` | `/api/study/free` | Free study — known + learning word decks |

### Ingest request shape
```json
{
  "url": "https://...",
  "title": "Page title",
  "page_purpose": "1–2 sentence description",
  "words": [{"word": "學習", "context_sentence": "..."}],
  "source_type": "extension_page"
}
```

---

## Local Development Setup

### Prerequisites
- Python 3.12+
- PostgreSQL running locally
- CC-CEDICT file from [mdbg.net](https://www.mdbg.net/chinese/dictionary?page=cedict)

### Backend
```bash
createdb mandarinreader
psql mandarinreader < backend/migrations/001_initial_schema.sql

# Place cedict_ts.u8 at backend/data/cedict_ts.u8
cd backend && python migrations/002_load_cedict.py

cd backend
pip install -r requirements.txt
uvicorn app.main:app --reload
```

### Chrome Extension
1. `chrome://extensions` → Enable Developer Mode → Load unpacked → select `extension/`
2. Open extension Options → enter your Claude API key + backend URL

### Environment Variables (`.env` in `backend/`)
```
DATABASE_URL=postgresql+asyncpg://localhost/mandarinreader
ANTHROPIC_API_KEY=sk-ant-...
MANDARINREADER_API_KEY=        # leave blank for local dev (auth skipped)
CORS_ORIGINS=*
```

---

## Cloud Deployment (Railway)

- **Backend URL:** `https://mandarinreader-production.up.railway.app`
- **Platform:** Railway hobby plan (~$5–7/mo, Postgres included)
- **Auth:** `X-API-Key` header required on all `/api/*` routes
- **Dockerfile:** `backend/Dockerfile` — `python:3.12-slim`, uvicorn on port 8000

Railway env vars to set: `DATABASE_URL` (auto-provided), `ANTHROPIC_API_KEY`, `MANDARINREADER_API_KEY`, `CORS_ORIGINS`, `PORT=8000`.

After provisioning a new Railway Postgres instance, run migrations:
```bash
psql "$RAILWAY_DATABASE_URL" < backend/migrations/001_initial_schema.sql
psql "$RAILWAY_DATABASE_URL" -c "ALTER TABLE cedict ADD CONSTRAINT cedict_traditional_pinyin_unique UNIQUE (traditional, pinyin);"
DATABASE_URL="$RAILWAY_DATABASE_URL" python backend/migrations/002_load_cedict.py
```

---

## Extension Flow

1. User clicks popup → "Capture This Page"
2. `popup.js` → `sendMessage` → `background.js`
3. `background.js` runs `executeScript` to extract visible text (8000 char limit)
4. Claude API call (Haiku, temp=0, max_tokens=2500) — extracts page purpose + key vocabulary
5. `POST /api/ingest` with `X-API-Key` header
6. Result stored in `chrome.storage.local`, displayed in popup

### Known Gotchas
- MV3 service workers are ephemeral — all state in `chrome.storage`, never module-level vars
- `host_permissions: ["<all_urls>"]` required for service worker to reach localhost
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
1. **Start Session** — select word count (5–50), fetches from `GET /api/queue?n=N`
2. **Flash phase** — character shown for 3 seconds, then hidden
3. **Writing phase** — user writes the character using the iOS Chinese handwriting keyboard (Traditional), typed text compared against target
4. **3 rounds per card** — 2+ correct = known, else learning; skip = known
5. **Summary** — shows results, syncs to backend via parallel `POST /api/review/{word_id}` calls
6. **Settings** — backend URL + API key stored in UserDefaults

### File Structure
```
ios/MandarinReader/MandarinReader/
├── MandarinReaderApp.swift           # Entry point, injects AppSettings
├── App/
│   ├── AppSettings.swift             # UserDefaults-backed backend config
│   └── SettingsView.swift            # Backend URL + API key form
├── Networking/
│   ├── APIClient.swift               # fetchQueue + submitReview (URLSession)
│   └── Models.swift                  # WordQueueItem, PendingReview, ReviewResult
├── Session/
│   └── SessionViewModel.swift        # State machine: flash → writing → feedback → summary
└── Views/
    ├── StartSessionView.swift        # Word count picker + Start button
    ├── PracticeView.swift            # Flash + TextField input + feedback loop
    ├── FeedbackOverlay.swift         # Correct/incorrect overlay badge
    └── SummaryView.swift             # Results + parallel sync
```

### Running on Device
1. Open `ios/MandarinReader/MandarinReader.xcodeproj` in Xcode
2. Signing & Capabilities → select your team, set a unique bundle ID
3. Enable Developer Mode on the iPad: Settings → Privacy & Security → Developer Mode (reboots device)
4. Select your iPad as destination → ⌘R
5. On iPad: Settings → General → VPN & Device Management → trust your developer profile
6. In the app: Settings → enter the Railway backend URL (or LAN IP for local dev) and the `MANDARINREADER_API_KEY`

---

## Development Log

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

- **Remaining iPad P1s** — retry double-submit guard on sync, URL trimming in Settings, HTTPS enforcement, mid-session exit handling, force-unwrap audit
- **Camera input** — OCR photos via Apple Vision (iOS) to pipe into corpus
- **Share sheet** — Accept text/images from any iOS app
- **Known-word bootstrapping** — Import HSK lists or placement test to seed familiarity scores
- **Traditional/Simplified toggle** — Currently Traditional-only; Simplified support planned
