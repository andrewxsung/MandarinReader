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
└── extension/
    ├── manifest.json            # MV3 manifest
    ├── background.js            # Service worker: Claude API + backend POST
    ├── popup.html / popup.js    # Extension popup UI
    └── options.html / options.js  # Settings: Claude key, backend URL, API key
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

### 2026-04-12 — Cloud Deployment + API Key Auth
- Added `backend/app/auth.py` — `verify_auth` FastAPI dependency checking `X-API-Key` header against `MANDARINREADER_API_KEY` env var. Auth skipped when env var is unset (local dev). Return type is `str` identity, designed for easy swap to JWT later.
- Applied auth to all `/api/*` routers via router-level `dependencies=[Depends(verify_auth)]`. `/health` remains public.
- CORS origins now configurable via `CORS_ORIGINS` env var (comma-separated, defaults to `*`).
- `database.py` auto-normalizes Railway's `postgresql://` format to `postgresql+asyncpg://`.
- Added `backend/Dockerfile` (`python:3.12-slim`, uvicorn on `0.0.0.0:8000`) and `.dockerignore`.
- Chrome extension updated: new "MandarinReader API Key" field in Options, `X-API-Key` header sent on all backend requests.
- Deployed to Railway: Postgres 16 with persistent volume, 114,943 CEDICT rows loaded. Backend live at `https://mandarinreader-production.up.railway.app`.

---

## Planned / Next Up

- **iPadOS companion app** — SwiftUI app for flashcard review and writing practice with Apple Pencil (PencilKit). Connects to the Railway backend. Vision framework OCR for character recognition is stretch goal.
- **Camera input** — OCR photos via Apple Vision (iOS) to pipe into corpus
- **Share sheet** — Accept text/images from any iOS app
- **Known-word bootstrapping** — Import HSK lists or placement test to seed familiarity scores
- **Traditional/Simplified toggle** — Currently Traditional-only; Simplified support planned
