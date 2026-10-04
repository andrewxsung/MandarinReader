# Accounts + Server-Side Claude Key Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add email/password accounts (DB-backed bearer tokens) and move the Claude API call server-side so users never enter an API key or backend URL.

**Architecture:** FastAPI backend gains `users`/`sessions` tables, argon2id password hashing, and a `get_current_user` dependency; all vocabulary data becomes per-user. `POST /api/ingest` now accepts raw page text and calls Claude Haiku server-side (key from `ANTHROPIC_API_KEY` env var) with a 50 captures/user/day rate limit. The Chrome extension loses its options page (backend URL hardcoded in `config.js`, login/signup in the popup); the iOS app stores the token in the Keychain behind a `LoginView`.

**Tech Stack:** FastAPI + SQLAlchemy async + asyncpg, argon2-cffi, `anthropic` AsyncAnthropic, pytest + pytest-asyncio + httpx (new), Chrome MV3 plain JS, SwiftUI + XCTest.

**Spec:** `docs/superpowers/specs/2026-08-08-accounts-and-server-side-claude-design.md`

**Prerequisites:** Local Postgres running. Run once before Task 1:

```bash
createdb mandarinreader_test
```

All backend commands run from `backend/` with the venv activated (`source venv/bin/activate`).

---

## File Structure Overview

| File | Action | Responsibility |
|---|---|---|
| `backend/requirements.txt` | Modify | Add argon2-cffi, email-validator |
| `backend/requirements-dev.txt` | Create | pytest, pytest-asyncio, httpx |
| `backend/pytest.ini` | Create | pytest config |
| `backend/tests/conftest.py` | Create | Test DB schema + client fixtures |
| `backend/tests/test_smoke.py` | Create | Infra sanity test |
| `backend/migrations/003_users_auth.sql` | Create | users/sessions tables, truncate + user_id columns |
| `backend/app/models.py` | Modify | `User`, `AuthSession`; `user_id` on `Word`/`Page` |
| `backend/app/services/security.py` | Create | Password hashing + token helpers |
| `backend/app/auth.py` | Rewrite | `get_current_user` bearer-token dependency |
| `backend/app/routers/auth.py` | Create | signup/login/logout/me |
| `backend/app/schemas.py` | Modify | Auth schemas; new IngestRequest/Response |
| `backend/app/crud.py` | Modify | user_id scoping |
| `backend/app/routers/{queue,review,words,study}.py` | Modify | user_id scoping |
| `backend/app/services/claude.py` | Create | Server-side page analysis (AsyncAnthropic) |
| `backend/app/routers/ingest.py` | Rewrite | page_text ingest + rate limit |
| `backend/app/main.py` | Modify | Router wiring, drop shared-key auth |
| `backend/test_ingest.py` | Delete | Legacy manual script (superseded) |
| `extension/config.js` | Create | `BACKEND_URL` constant |
| `extension/background.js` | Rewrite | Relay page text to backend; no Claude |
| `extension/options.html`, `extension/options.js` | Delete | No more user settings |
| `extension/manifest.json` | Modify | Drop options page, narrow host permissions |
| `extension/popup.html`, `extension/popup.js` | Rewrite | Login/signup view + capture view |
| `ios/.../App/AppConfig.swift` | Create | Hardcoded base URL |
| `ios/.../App/TokenStorage.swift` | Create | Protocol + Keychain + in-memory impls |
| `ios/.../Networking/APIClient.swift` | Modify | Bearer auth + signup/login/logout |
| `ios/.../App/AuthStore.swift` | Create | Observable auth state (replaces AppSettings) |
| `ios/.../App/LoginView.swift` | Create | Sign-in/sign-up screen |
| `ios/.../App/SettingsView.swift` | Modify | Account section instead of URL/key fields |
| `ios/.../Views/StartSessionView.swift` | Modify | Use AuthStore |
| `ios/.../MandarinReaderApp.swift` | Modify | Gate on sign-in |
| `ios/.../App/AppSettings.swift` | Delete | Replaced by AuthStore |
| `ios/MandarinReader/MandarinReaderTests/AppSettingsTests.swift` | Delete | Replaced by AuthStoreTests |

The Xcode project uses file-system-synchronized groups (objectVersion 77), so new/deleted `.swift` files under the app folder are picked up automatically — no pbxproj edits needed.

---

### Task 1: Backend test infrastructure

**Files:**
- Create: `backend/requirements-dev.txt`
- Create: `backend/pytest.ini`
- Create: `backend/tests/__init__.py` (empty)
- Create: `backend/tests/conftest.py`
- Create: `backend/tests/test_smoke.py`
- Modify: `backend/requirements.txt`

- [ ] **Step 1: Add dependencies**

`backend/requirements-dev.txt` (new):

```
pytest==8.3.2
pytest-asyncio==0.24.0
httpx==0.27.0
```

Append to `backend/requirements.txt`:

```
argon2-cffi==23.1.0
email-validator==2.2.0
```

Install:

```bash
pip install -r requirements.txt -r requirements-dev.txt
```

- [ ] **Step 2: Create pytest config**

`backend/pytest.ini`:

```ini
[pytest]
asyncio_mode = auto
asyncio_default_fixture_loop_scope = function
testpaths = tests
```

- [ ] **Step 3: Create conftest**

`backend/tests/conftest.py`:

```python
import os

# Must be set BEFORE app.database is imported (it reads DATABASE_URL at import time).
os.environ["DATABASE_URL"] = os.environ.get(
    "TEST_DATABASE_URL", "postgresql+asyncpg://localhost/mandarinreader_test"
)
os.environ.pop("ANTHROPIC_API_KEY", None)  # tests must never hit the real API

import pytest_asyncio  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402

from app.database import AsyncSessionLocal, Base, engine  # noqa: E402
from app.main import app  # noqa: E402


@pytest_asyncio.fixture(autouse=True)
async def _fresh_schema():
    """Create all tables before each test, drop after. Slow but isolated.

    Also disposes the engine so no asyncpg connection outlives the test's
    event loop (pytest-asyncio uses one loop per test).
    """
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


@pytest_asyncio.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest_asyncio.fixture
async def db():
    """Direct DB session for test setup/assertions."""
    async with AsyncSessionLocal() as session:
        yield session
```

- [ ] **Step 4: Write smoke test**

`backend/tests/test_smoke.py`:

```python
async def test_health(client):
    resp = await client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
```

- [ ] **Step 5: Run it**

```bash
cd backend && pytest -v
```

Expected: `test_health PASSED`. (If the DB doesn't exist: `createdb mandarinreader_test`.)

- [ ] **Step 6: Commit**

```bash
git add backend/requirements.txt backend/requirements-dev.txt backend/pytest.ini backend/tests/
git commit -m "test: add pytest infrastructure with test database"
```

**Decisions (recorded during implementation):**

- **Test schema comes from the SQLAlchemy models, not the SQL migrations.** The
  `db_schema` fixture builds tables via `Base.metadata.create_all`, so the tests
  exercise `app/models.py` — they do *not* validate that
  `migrations/003_users_auth.sql` matches. Migration 003 correctness is verified
  separately against the dev DB in Task 2, Step 6. Keep that step: nothing in the
  test suite will catch model/migration drift.
- **Requirements pins were bumped beyond the original plan.** `asyncpg` 0.29.0 and
  `pydantic` 2.8.0 do not build on Python 3.13 (the venv's interpreter), so they
  were raised to 0.31.0 and 2.13.0, and `anthropic` to `>=0.94.0`, matching what
  was already installed. Authorized deviation, not drive-by version churn.
- **Fixture layout deviates from the Step 3 snippet above.** `_fresh_schema` became
  a non-autouse fixture named `db_schema`, depended on by `client` and `db`, so
  later pure-unit tests (password hashing, token helpers) run without Postgres.
  `ANTHROPIC_API_KEY` is overwritten with a dummy sentinel rather than popped,
  because `load_dotenv()` in `app/database.py` would otherwise re-populate a
  popped var from `backend/.env`. See `backend/tests/conftest.py` for the
  as-built version.

---

### Task 2: User/AuthSession models + migration 003

**Files:**
- Modify: `backend/app/models.py`
- Create: `backend/migrations/003_users_auth.sql`
- Create: `backend/tests/test_models.py`

- [ ] **Step 1: Write failing test**

`backend/tests/test_models.py`:

```python
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy.exc import IntegrityError

from app.models import AuthSession, User, Word


def _word(user_id: int, traditional: str) -> Word:
    now = datetime.now(timezone.utc)
    return Word(
        user_id=user_id, traditional=traditional, familiarity_score=0,
        encounter_count=1, source_diversity_count=1, priority_score=1.0,
        ease_factor=2.5, srs_interval_days=1, created_at=now, updated_at=now,
    )


async def test_word_unique_per_user_not_global(db):
    now = datetime.now(timezone.utc)
    a = User(email="a@x.com", password_hash="h", created_at=now)
    b = User(email="b@x.com", password_hash="h", created_at=now)
    db.add_all([a, b])
    await db.flush()

    db.add(_word(a.id, "貓"))
    db.add(_word(b.id, "貓"))  # same word, different user — allowed
    await db.commit()


async def test_word_duplicate_same_user_rejected(db):
    now = datetime.now(timezone.utc)
    a = User(email="a@x.com", password_hash="h", created_at=now)
    db.add(a)
    await db.flush()

    db.add(_word(a.id, "貓"))
    await db.commit()
    db.add(_word(a.id, "貓"))
    with pytest.raises(IntegrityError):
        await db.commit()


async def test_auth_session_links_user(db):
    now = datetime.now(timezone.utc)
    a = User(email="a@x.com", password_hash="h", created_at=now)
    db.add(a)
    await db.flush()
    db.add(AuthSession(
        user_id=a.id, token_hash="abc123", created_at=now,
        expires_at=now + timedelta(days=30),
    ))
    await db.commit()
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_models.py -v
```

Expected: FAIL — `ImportError: cannot import name 'AuthSession'`.

- [ ] **Step 3: Update models.py**

In `backend/app/models.py`, extend the sqlalchemy import to include `UniqueConstraint`:

```python
from sqlalchemy import (
    Integer, Text, Numeric, Date, TIMESTAMP, ForeignKey, Enum as SAEnum, Index,
    UniqueConstraint,
)
```

Add after the `SourceType` enum:

```python
class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    email: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)


class AuthSession(Base):
    __tablename__ = "sessions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    token_hash: Mapped[str] = mapped_column(Text, nullable=False, unique=True)
    created_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), nullable=False)
    last_used_at: Mapped[datetime | None] = mapped_column(TIMESTAMP(timezone=True))
```

In `Word`: change `traditional` to non-unique, add `user_id` and the composite constraint:

```python
class Word(Base):
    __tablename__ = "words"
    __table_args__ = (UniqueConstraint("user_id", "traditional", name="words_user_traditional_key"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    traditional: Mapped[str] = mapped_column(Text, nullable=False)
    # ... rest of the columns unchanged
```

In `Page`, add after `id`:

```python
    user_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
```

- [ ] **Step 4: Run tests**

```bash
pytest tests/test_models.py -v
```

Expected: 3 PASSED.

- [ ] **Step 5: Write migration**

`backend/migrations/003_users_auth.sql`:

```sql
-- Accounts + per-user data. DESTRUCTIVE: wipes existing vocabulary data
-- (start-fresh decision — see docs/superpowers/specs/2026-08-08-accounts-and-server-side-claude-design.md).
-- Run: psql mandarinreader < migrations/003_users_auth.sql

BEGIN;

CREATE TABLE users (
    id            SERIAL PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,          -- stored lowercased
    password_hash TEXT NOT NULL,                 -- argon2id
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE sessions (
    id           SERIAL PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash   TEXT NOT NULL UNIQUE,           -- sha256 hex of the raw bearer token
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at   TIMESTAMPTZ NOT NULL,
    last_used_at TIMESTAMPTZ
);
CREATE INDEX idx_sessions_user_id ON sessions (user_id);

TRUNCATE encounters, words, pages RESTART IDENTITY CASCADE;

ALTER TABLE words ADD COLUMN user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE words DROP CONSTRAINT words_traditional_key;
ALTER TABLE words ADD CONSTRAINT words_user_traditional_key UNIQUE (user_id, traditional);
CREATE INDEX idx_words_user_id ON words (user_id);

ALTER TABLE pages ADD COLUMN user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE;
CREATE INDEX idx_pages_user_id ON pages (user_id);

COMMIT;
```

- [ ] **Step 6: Apply migration to the dev database and verify**

```bash
psql mandarinreader < migrations/003_users_auth.sql
psql mandarinreader -c "\d words" | head -8
```

Expected: no errors; `user_id | integer | not null` appears. (If the drop fails because the constraint has a different name, find it with `psql mandarinreader -c "\d words"` and adjust.)

- [ ] **Step 7: Commit**

```bash
git add backend/app/models.py backend/migrations/003_users_auth.sql backend/tests/test_models.py
git commit -m "feat: add users/sessions tables and per-user word scoping (migration 003)"
```

---

### Task 3: Security service (password hashing + tokens)

**Files:**
- Create: `backend/app/services/security.py`
- Create: `backend/tests/test_security.py`

- [ ] **Step 1: Write failing test**

`backend/tests/test_security.py`:

```python
from app.services.security import hash_password, hash_token, new_token, verify_password


def test_password_roundtrip():
    h = hash_password("correct horse battery")
    assert h != "correct horse battery"
    assert h.startswith("$argon2id$")
    assert verify_password(h, "correct horse battery") is True


def test_wrong_password_rejected():
    h = hash_password("right")
    assert verify_password(h, "wrong") is False


def test_garbage_hash_rejected_not_raised():
    assert verify_password("not-a-hash", "anything") is False


def test_tokens_are_unique_and_hashed_deterministically():
    t1, t2 = new_token(), new_token()
    assert t1 != t2
    assert len(t1) >= 40
    assert hash_token(t1) == hash_token(t1)
    assert hash_token(t1) != hash_token(t2)
    assert len(hash_token(t1)) == 64  # sha256 hex
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_security.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'app.services.security'`.

- [ ] **Step 3: Implement**

`backend/app/services/security.py`:

```python
import hashlib
import secrets

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

_hasher = PasswordHasher()  # argon2id with library defaults


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _hasher.verify(password_hash, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def new_token() -> str:
    """Random 256-bit bearer token, URL-safe."""
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    """Tokens are stored hashed so a DB leak doesn't leak live sessions."""
    return hashlib.sha256(token.encode()).hexdigest()
```

- [ ] **Step 4: Run tests**

```bash
pytest tests/test_security.py -v
```

Expected: 4 PASSED.

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/security.py backend/tests/test_security.py
git commit -m "feat: add argon2id password hashing and token helpers"
```

---

### Task 4: Auth endpoints + get_current_user dependency

**Files:**
- Rewrite: `backend/app/auth.py`
- Create: `backend/app/routers/auth.py`
- Modify: `backend/app/schemas.py` (add auth schemas)
- Modify: `backend/app/main.py`
- Create: `backend/tests/test_auth.py`

- [ ] **Step 1: Write failing tests**

`backend/tests/test_auth.py`:

```python
from datetime import datetime, timedelta, timezone

from sqlalchemy import select, update

from app.models import AuthSession

SIGNUP = {"email": "andrew@example.com", "password": "password123"}


async def test_signup_returns_token(client):
    resp = await client.post("/api/auth/signup", json=SIGNUP)
    assert resp.status_code == 201
    body = resp.json()
    assert body["email"] == "andrew@example.com"
    assert len(body["token"]) >= 40


async def test_signup_normalizes_email_and_rejects_duplicates(client):
    await client.post("/api/auth/signup", json=SIGNUP)
    resp = await client.post(
        "/api/auth/signup", json={"email": "Andrew@Example.COM", "password": "different123"}
    )
    assert resp.status_code == 409


async def test_signup_short_password_rejected(client):
    resp = await client.post("/api/auth/signup", json={"email": "a@x.com", "password": "short"})
    assert resp.status_code == 422


async def test_login_success(client):
    await client.post("/api/auth/signup", json=SIGNUP)
    resp = await client.post("/api/auth/login", json=SIGNUP)
    assert resp.status_code == 200
    assert len(resp.json()["token"]) >= 40


async def test_login_failures_are_generic(client):
    await client.post("/api/auth/signup", json=SIGNUP)
    wrong_pw = await client.post(
        "/api/auth/login", json={"email": SIGNUP["email"], "password": "wrongwrong1"}
    )
    unknown = await client.post(
        "/api/auth/login", json={"email": "nobody@example.com", "password": "password123"}
    )
    assert wrong_pw.status_code == unknown.status_code == 401
    assert wrong_pw.json()["detail"] == unknown.json()["detail"]


async def test_me_requires_and_accepts_token(client):
    anon = await client.get("/api/auth/me")
    assert anon.status_code == 401

    signup = await client.post("/api/auth/signup", json=SIGNUP)
    token = signup.json()["token"]
    me = await client.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200
    assert me.json()["email"] == "andrew@example.com"


async def test_logout_revokes_token(client):
    signup = await client.post("/api/auth/signup", json=SIGNUP)
    headers = {"Authorization": f"Bearer {signup.json()['token']}"}
    assert (await client.post("/api/auth/logout", headers=headers)).status_code == 204
    assert (await client.get("/api/auth/me", headers=headers)).status_code == 401


async def test_expired_session_rejected(client, db):
    signup = await client.post("/api/auth/signup", json=SIGNUP)
    headers = {"Authorization": f"Bearer {signup.json()['token']}"}
    await db.execute(update(AuthSession).values(
        expires_at=datetime.now(timezone.utc) - timedelta(seconds=1)
    ))
    await db.commit()
    assert (await client.get("/api/auth/me", headers=headers)).status_code == 401


async def test_active_session_expiry_slides(client, db):
    signup = await client.post("/api/auth/signup", json=SIGNUP)
    headers = {"Authorization": f"Bearer {signup.json()['token']}"}
    # Simulate a session 10 days into its 30-day window
    stale = datetime.now(timezone.utc) + timedelta(days=20)
    await db.execute(update(AuthSession).values(expires_at=stale))
    await db.commit()

    assert (await client.get("/api/auth/me", headers=headers)).status_code == 200

    sess = (await db.execute(select(AuthSession))).scalar_one()
    await db.refresh(sess)
    assert sess.expires_at > stale + timedelta(days=8)  # slid back to ~now+30d
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_auth.py -v
```

Expected: all FAIL with 404s (routes don't exist).

- [ ] **Step 3: Add auth schemas**

Append to `backend/app/schemas.py`:

```python
# --- Auth ---

from pydantic import EmailStr, Field  # move to the top imports


class CredentialsRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=200)


class AuthResponse(BaseModel):
    token: str
    email: str


class MeResponse(BaseModel):
    email: str
```

(Put the `EmailStr, Field` import on the existing `from pydantic import BaseModel` line.)

- [ ] **Step 4: Rewrite app/auth.py**

Replace the entire contents of `backend/app/auth.py`:

```python
from datetime import datetime, timedelta, timezone

from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .database import get_db
from .models import AuthSession, User
from .services.security import hash_token

bearer_scheme = HTTPBearer(auto_error=False)

SESSION_TTL = timedelta(days=30)
# Only write the slid expiry when it has drifted by more than this,
# so routine reads don't cause a DB write per request.
SLIDE_WRITE_THRESHOLD = timedelta(days=1)


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    if credentials is None:
        raise HTTPException(status_code=401, detail="Not authenticated")

    now = datetime.now(timezone.utc)
    result = await db.execute(
        select(AuthSession, User)
        .join(User, User.id == AuthSession.user_id)
        .where(AuthSession.token_hash == hash_token(credentials.credentials))
    )
    row = result.first()
    if row is None or row[0].expires_at <= now:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    session, user = row
    if (now + SESSION_TTL) - session.expires_at > SLIDE_WRITE_THRESHOLD:
        session.expires_at = now + SESSION_TTL
        session.last_used_at = now
        await db.commit()

    return user
```

> Note: `get_current_user` may leave an open read transaction on the request's
> session. Handlers must therefore use plain statements + `await db.commit()`,
> **not** `async with db.begin()` (which raises if a transaction is already
> active). Tasks 5 and 6 convert the two existing `db.begin()` call sites.

- [ ] **Step 5: Create the auth router**

`backend/app/routers/auth.py`:

```python
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import SESSION_TTL, bearer_scheme, get_current_user
from ..database import get_db
from ..models import AuthSession, User
from ..schemas import AuthResponse, CredentialsRequest, MeResponse
from ..services.security import hash_password, hash_token, new_token, verify_password

router = APIRouter()


async def _open_session(db: AsyncSession, user_id: int) -> str:
    token = new_token()
    now = datetime.now(timezone.utc)
    db.add(AuthSession(
        user_id=user_id,
        token_hash=hash_token(token),
        created_at=now,
        expires_at=now + SESSION_TTL,
    ))
    return token


@router.post("/auth/signup", response_model=AuthResponse, status_code=201)
async def signup(payload: CredentialsRequest, db: AsyncSession = Depends(get_db)):
    email = payload.email.lower().strip()
    existing = await db.scalar(select(User.id).where(User.email == email))
    if existing is not None:
        raise HTTPException(status_code=409, detail="An account with this email already exists")

    user = User(
        email=email,
        password_hash=hash_password(payload.password),
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.flush()
    token = await _open_session(db, user.id)
    await db.commit()
    return AuthResponse(token=token, email=email)


@router.post("/auth/login", response_model=AuthResponse)
async def login(payload: CredentialsRequest, db: AsyncSession = Depends(get_db)):
    email = payload.email.lower().strip()
    user = await db.scalar(select(User).where(User.email == email))
    if user is None or not verify_password(user.password_hash, payload.password):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    token = await _open_session(db, user.id)
    await db.commit()
    return AuthResponse(token=token, email=email)


@router.post("/auth/logout", status_code=204)
async def logout(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db),
):
    if credentials is not None:
        await db.execute(
            delete(AuthSession).where(AuthSession.token_hash == hash_token(credentials.credentials))
        )
        await db.commit()


@router.get("/auth/me", response_model=MeResponse)
async def me(user: User = Depends(get_current_user)):
    return MeResponse(email=user.email)
```

- [ ] **Step 6: Update main.py wiring**

In `backend/app/main.py`: replace the import of `verify_auth` and the router block:

```python
from .routers import auth, ingest, queue, review, words
from .routers import study
```

(remove `from .auth import verify_auth`), and replace the `_auth = [...]` + `include_router` block with:

```python
app.include_router(auth.router, prefix="/api", tags=["auth"])
app.include_router(ingest.router, prefix="/api", tags=["ingest"])
app.include_router(queue.router, prefix="/api", tags=["queue"])
app.include_router(review.router, prefix="/api", tags=["review"])
app.include_router(words.router, prefix="/api", tags=["words"])
app.include_router(study.router, prefix="/api", tags=["study"])
```

> The data routers are momentarily unauthenticated; Task 5 adds
> `Depends(get_current_user)` to every handler. Both land in the same branch.

- [ ] **Step 7: Run tests**

```bash
pytest tests/test_auth.py -v && pytest -v
```

Expected: all PASS (including earlier tests).

- [ ] **Step 8: Commit**

```bash
git add backend/app/auth.py backend/app/routers/auth.py backend/app/schemas.py backend/app/main.py backend/tests/test_auth.py
git commit -m "feat: email/password auth with DB-backed bearer sessions"
```

---

### Task 5: Per-user data scoping

**Files:**
- Modify: `backend/app/crud.py`
- Modify: `backend/app/routers/queue.py`, `review.py`, `words.py`, `study.py`
- Create: `backend/tests/test_user_isolation.py`

- [ ] **Step 1: Write failing tests**

`backend/tests/test_user_isolation.py`:

```python
from datetime import datetime, timezone

from sqlalchemy import select

from app.models import User, Word


async def _signup(client, email: str) -> dict:
    resp = await client.post("/api/auth/signup", json={"email": email, "password": "password123"})
    return {"Authorization": f"Bearer {resp.json()['token']}"}


async def _make_word(db, email: str, traditional: str) -> Word:
    user_id = (await db.execute(select(User.id).where(User.email == email))).scalar_one()
    now = datetime.now(timezone.utc)
    word = Word(
        user_id=user_id, traditional=traditional, familiarity_score=0,
        encounter_count=1, source_diversity_count=1, priority_score=1.0,
        ease_factor=2.5, srs_interval_days=1, created_at=now, updated_at=now,
    )
    db.add(word)
    await db.commit()
    await db.refresh(word)
    return word


async def test_queue_is_per_user(client, db):
    headers_a = await _signup(client, "a@x.com")
    headers_b = await _signup(client, "b@x.com")
    await _make_word(db, "a@x.com", "貓")
    await _make_word(db, "b@x.com", "狗")

    queue_a = (await client.get("/api/queue", headers=headers_a)).json()
    queue_b = (await client.get("/api/queue", headers=headers_b)).json()
    assert [w["traditional"] for w in queue_a] == ["貓"]
    assert [w["traditional"] for w in queue_b] == ["狗"]


async def test_queue_requires_auth(client):
    assert (await client.get("/api/queue")).status_code == 401


async def test_words_list_is_per_user(client, db):
    headers_a = await _signup(client, "a@x.com")
    await _signup(client, "b@x.com")
    await _make_word(db, "b@x.com", "狗")
    assert (await client.get("/api/words", headers=headers_a)).json() == []


async def test_cannot_review_another_users_word(client, db):
    headers_a = await _signup(client, "a@x.com")
    await _signup(client, "b@x.com")
    word_b = await _make_word(db, "b@x.com", "狗")

    resp = await client.post(
        f"/api/review/{word_b.id}", json={"result": "known"}, headers=headers_a
    )
    assert resp.status_code == 404


async def test_review_own_word_works(client, db):
    headers_a = await _signup(client, "a@x.com")
    word_a = await _make_word(db, "a@x.com", "貓")
    resp = await client.post(
        f"/api/review/{word_a.id}", json={"result": "known"}, headers=headers_a
    )
    assert resp.status_code == 200
    assert resp.json()["familiarity_score"] == 2


async def test_word_lookup_scoped_to_user(client, db):
    headers_a = await _signup(client, "a@x.com")
    await _signup(client, "b@x.com")
    await _make_word(db, "b@x.com", "狗")

    resp = await client.get("/api/word/狗", headers=headers_a)
    # Not in A's corpus and test cedict table is empty → 404
    assert resp.status_code == 404


async def test_study_endpoints_scoped(client, db):
    headers_a = await _signup(client, "a@x.com")
    await _signup(client, "b@x.com")
    await _make_word(db, "b@x.com", "狗")

    free = (await client.get("/api/study/free", headers=headers_a)).json()
    assert free == {"known_practice": [], "new_learning": []}
    plan = (await client.get("/api/study/plan", headers=headers_a)).json()
    assert plan["words"] == []
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_user_isolation.py -v
```

Expected: FAIL (queue returns 200 without auth, cross-user data visible, etc.).

- [ ] **Step 3: Scope crud.py by user**

In `backend/app/crud.py`:

`create_page` gains `user_id`:

```python
async def create_page(
    db: AsyncSession,
    user_id: int,
    url: str,
    title: str | None,
    page_purpose: str | None,
) -> Page:
    page = Page(
        user_id=user_id,
        url=url,
        title=title,
        page_purpose=page_purpose,
        captured_at=datetime.now(timezone.utc),
    )
    db.add(page)
    await db.flush()
    return page
```

`upsert_word` gains `user_id`; the lookup and insert both use it:

```python
async def upsert_word(
    db: AsyncSession,
    user_id: int,
    word_text: str,
    source_type: str,
    source_url: str | None,
    context_sentence: str | None,
) -> tuple[Word, bool]:
    result = await db.execute(
        select(Word)
        .where(Word.user_id == user_id, Word.traditional == word_text)
        .with_for_update()
    )
    # ... unchanged until the Word(...) constructor, which gains:
        word = Word(
            user_id=user_id,
            traditional=word_text,
            # ... rest unchanged
        )
```

`get_queue` gains `user_id` and filters on it:

```python
async def get_queue(db: AsyncSession, user_id: int, n: int = 20) -> list[tuple[Word, str | None]]:
    ...
    result = await db.execute(
        select(Word)
        .where(
            Word.user_id == user_id,
            Word.familiarity_score.in_([0, 1]),
            or_(
                Word.next_review_date == None,
                Word.next_review_date <= today,
            ),
        )
        .order_by(Word.priority_score.desc())
        .limit(n)
    )
```

- [ ] **Step 4: Scope the routers**

`backend/app/routers/queue.py` — add the user dependency:

```python
from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from ..auth import get_current_user
from ..database import get_db
from ..crud import get_queue
from ..models import User
from ..schemas import WordQueueItem

router = APIRouter()


@router.get("/queue", response_model=list[WordQueueItem])
async def queue(
    n: int = Query(default=20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    items = await get_queue(db, user.id, n)
    # ... list comprehension unchanged
```

`backend/app/routers/review.py` — ownership check, and replace `async with db.begin()` with explicit commit (required now that `get_current_user` may hold an open transaction):

```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..auth import get_current_user
from ..database import get_db
from ..models import User, Word
from ..services.srs import apply_review
from ..services.priority import compute_priority
from ..schemas import ReviewRequest, ReviewResponse

router = APIRouter()


@router.post("/review/{word_id}", response_model=ReviewResponse)
async def review(
    word_id: int,
    payload: ReviewRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Word)
        .where(Word.id == word_id, Word.user_id == user.id)
        .with_for_update()
    )
    word = result.scalar_one_or_none()
    if word is None:
        raise HTTPException(status_code=404, detail="Word not found")

    apply_review(word, payload.result)
    word.priority_score = compute_priority(word)
    await db.commit()

    return ReviewResponse(
        id=word.id,
        familiarity_score=word.familiarity_score,
        next_review_date=word.next_review_date,
        ease_factor=float(word.ease_factor),
        srs_interval_days=word.srs_interval_days,
    )
```

`backend/app/routers/words.py` — add `user: User = Depends(get_current_user)` to all three handlers (imports: `from ..auth import get_current_user`, add `User` to the models import). Add filters:

- `list_words`: `select(Word).where(Word.user_id == user.id)...`
- `get_recent`: pages query `select(Page).where(Page.user_id == user.id)...`; words query adds `.where(Word.user_id == user.id)`
- `get_word`: corpus query `select(Word).where(Word.user_id == user.id, Word.traditional == word)` (cedict fallback unchanged — it's a shared dictionary)

`backend/app/routers/study.py` — add the same dependency to both handlers (imports: `from ..auth import get_current_user`, add `User` to models import). Add `Word.user_id == user.id` to the `where(...)` in `get_study_plan`, and to both queries in `get_free_study`.

- [ ] **Step 5: Run tests**

```bash
pytest tests/test_user_isolation.py -v && pytest -v
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/app/crud.py backend/app/routers/ backend/tests/test_user_isolation.py
git commit -m "feat: scope all vocabulary data per user"
```

---

### Task 6: Server-side Claude analysis + new ingest endpoint

**Files:**
- Create: `backend/app/services/claude.py`
- Modify: `backend/app/schemas.py` (IngestRequest/IngestResponse)
- Rewrite: `backend/app/routers/ingest.py`
- Create: `backend/tests/test_ingest_api.py`
- Delete: `backend/test_ingest.py` (legacy manual script)

- [ ] **Step 1: Write failing tests**

`backend/tests/test_ingest_api.py`:

```python
from datetime import datetime, timezone

from sqlalchemy import select

from app.models import Page, User
from app.services import claude

PAYLOAD = {
    "url": "https://example.com/news",
    "title": "測試",
    "page_text": "這是一篇關於貓和狗的文章。" * 3,
}


def fake_analysis(*words: str):
    async def _fake(page_text: str) -> claude.PageAnalysis:
        return claude.PageAnalysis(
            page_purpose="A test article about pets.",
            key_words=[claude.ExtractedWord(word=w, context_sentence="這是句子") for w in words],
        )
    return _fake


async def _signup(client, email="a@x.com") -> dict:
    resp = await client.post("/api/auth/signup", json={"email": email, "password": "password123"})
    return {"Authorization": f"Bearer {resp.json()['token']}"}


async def test_ingest_calls_claude_and_stores_words(client, monkeypatch):
    monkeypatch.setattr(claude, "analyze_page", fake_analysis("貓", "狗", "cat123"))
    headers = await _signup(client)

    resp = await client.post("/api/ingest", json=PAYLOAD, headers=headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["words_added"] == 2          # "cat123" filtered by is_cjk
    assert body["words_updated"] == 0
    assert body["page_purpose"] == "A test article about pets."
    assert body["total_words"] == 3

    queue = (await client.get("/api/queue", headers=headers)).json()
    assert sorted(w["traditional"] for w in queue) == ["狗", "貓"]


async def test_ingest_requires_auth(client):
    assert (await client.post("/api/ingest", json=PAYLOAD)).status_code == 401


async def test_ingest_claude_failure_returns_502(client, monkeypatch):
    async def _boom(page_text: str):
        raise claude.AnalysisError("upstream error")
    monkeypatch.setattr(claude, "analyze_page", _boom)
    headers = await _signup(client)

    resp = await client.post("/api/ingest", json=PAYLOAD, headers=headers)
    assert resp.status_code == 502


async def test_ingest_rate_limited_at_50_per_day(client, db, monkeypatch):
    monkeypatch.setattr(claude, "analyze_page", fake_analysis("貓"))
    headers = await _signup(client)

    user_id = (await db.execute(select(User.id))).scalar_one()
    now = datetime.now(timezone.utc)
    db.add_all([
        Page(user_id=user_id, url=f"https://x.com/{i}", captured_at=now)
        for i in range(50)
    ])
    await db.commit()

    resp = await client.post("/api/ingest", json=PAYLOAD, headers=headers)
    assert resp.status_code == 429


async def test_ingest_rejects_oversized_text(client):
    headers = await _signup(client)
    too_big = {**PAYLOAD, "page_text": "字" * 8001}
    assert (await client.post("/api/ingest", json=too_big, headers=headers)).status_code == 422


async def test_parse_claude_json_strips_code_fences():
    raw = '```json\n{"page_purpose": "p", "key_words": []}\n```'
    analysis = claude.parse_analysis(raw)
    assert analysis.page_purpose == "p"
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_ingest_api.py -v
```

Expected: FAIL — `ImportError` (no `app.services.claude`).

- [ ] **Step 3: Create the Claude service**

`backend/app/services/claude.py`:

```python
"""Server-side page analysis via Claude Haiku.

The prompt is moved verbatim from the old extension/background.js — the
extension no longer talks to Anthropic directly.
"""
import json

from anthropic import AsyncAnthropic
from pydantic import BaseModel, ValidationError

CLAUDE_MODEL = "claude-haiku-4-5-20251001"
MAX_TOKENS = 2500


class ExtractedWord(BaseModel):
    word: str
    context_sentence: str | None = None


class PageAnalysis(BaseModel):
    page_purpose: str
    key_words: list[ExtractedWord]


class AnalysisError(Exception):
    """Claude call or response parsing failed."""


PROMPT_TEMPLATE = """You are a Mandarin Chinese vocabulary extraction assistant.

Given the text of a Chinese-language webpage:
1. Write a 1-2 sentence summary of the page's topic and purpose in English.
2. Identify the 20-30 most important Traditional Chinese vocabulary words that a reader needs to understand to comprehend this page. Focus on content words (nouns, verbs, adjectives) that are specific to the topic — not common everyday function words like 的、是、了、在、有.

Rules:
- Output ONLY valid JSON. Do not include markdown, code fences, or any explanation outside the JSON.
- Only include Traditional Chinese words or phrases (1-4 characters each). Do not include English, numbers, or punctuation.
- The context_sentence field must be a short verbatim excerpt from the page text containing the word (max 30 characters).
- If the page contains no meaningful Chinese text, return: {{"page_purpose": "No Chinese content detected", "key_words": []}}

Output format:
{{
  "page_purpose": "<1-2 sentence description of page topic in English>",
  "key_words": [
    {{"word": "<Traditional Chinese word>", "context_sentence": "<verbatim sentence from page containing this word>"}},
    ...
  ]
}}

Page text:
---
{page_text}
---"""

_client: AsyncAnthropic | None = None


def _get_client() -> AsyncAnthropic:
    global _client
    if _client is None:
        _client = AsyncAnthropic()  # reads ANTHROPIC_API_KEY from the environment
    return _client


def parse_analysis(raw: str) -> PageAnalysis:
    # Strip markdown code fences if Claude adds them despite instructions
    cleaned = raw.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("\n", 1)[1] if "\n" in cleaned else cleaned
        cleaned = cleaned.rsplit("```", 1)[0]
    try:
        return PageAnalysis.model_validate(json.loads(cleaned))
    except (json.JSONDecodeError, ValidationError) as exc:
        raise AnalysisError(f"unparseable Claude response: {exc}") from exc


async def analyze_page(page_text: str) -> PageAnalysis:
    try:
        response = await _get_client().messages.create(
            model=CLAUDE_MODEL,
            max_tokens=MAX_TOKENS,
            temperature=0,
            messages=[{"role": "user", "content": PROMPT_TEMPLATE.format(page_text=page_text)}],
        )
    except Exception as exc:
        raise AnalysisError(f"Claude API error: {exc}") from exc
    return parse_analysis(response.content[0].text)
```

- [ ] **Step 4: Update schemas**

In `backend/app/schemas.py`, replace `WordInput`/`IngestRequest`/`IngestResponse` with:

```python
class IngestRequest(BaseModel):
    url: str
    title: str | None = None
    page_text: str = Field(min_length=10, max_length=8000)


class IngestResponse(BaseModel):
    words_added: int
    words_updated: int
    page_id: int
    page_purpose: str
    total_words: int
```

(`WordInput` is deleted — the word list now comes from Claude server-side.)

- [ ] **Step 5: Rewrite the ingest router**

Replace `backend/app/routers/ingest.py`:

```python
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_current_user
from ..crud import create_page, is_cjk, upsert_word
from ..database import get_db
from ..models import Page, User
from ..schemas import IngestRequest, IngestResponse
from ..services import claude

router = APIRouter()

DAILY_CAPTURE_LIMIT = 50


@router.post("/ingest", response_model=IngestResponse)
async def ingest(
    payload: IngestRequest,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
):
    day_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    captures_today = await db.scalar(
        select(func.count(Page.id)).where(Page.user_id == user.id, Page.captured_at >= day_start)
    )
    # Close the read transaction before the (slow) Claude call so we don't
    # hold a DB connection open for seconds.
    await db.rollback()
    if captures_today >= DAILY_CAPTURE_LIMIT:
        raise HTTPException(status_code=429, detail="Daily capture limit reached — try again tomorrow")

    try:
        analysis = await claude.analyze_page(payload.page_text)
    except claude.AnalysisError:
        raise HTTPException(status_code=502, detail="Analysis failed — try again")

    page = await create_page(db, user.id, payload.url, payload.title, analysis.page_purpose)
    added = 0
    updated = 0
    for extracted in analysis.key_words:
        if not is_cjk(extracted.word):
            continue
        _, is_new = await upsert_word(
            db, user.id, extracted.word, "extension_page", payload.url, extracted.context_sentence
        )
        if is_new:
            added += 1
        else:
            updated += 1
    await db.commit()

    return IngestResponse(
        words_added=added,
        words_updated=updated,
        page_id=page.id,
        page_purpose=analysis.page_purpose,
        total_words=len(analysis.key_words),
    )
```

- [ ] **Step 6: Delete the legacy script**

```bash
git rm backend/test_ingest.py
```

- [ ] **Step 7: Run tests**

```bash
pytest tests/test_ingest_api.py -v && pytest -v
```

Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add backend/app/services/claude.py backend/app/schemas.py backend/app/routers/ingest.py backend/tests/test_ingest_api.py
git commit -m "feat: move Claude page analysis server-side with daily rate limit"
```

---

### Task 7: Backend cleanup + manual end-to-end check

**Files:**
- Modify: `README.md` (dev setup section)

- [ ] **Step 1: Grep for leftovers**

```bash
grep -rn "MANDARINREADER_API_KEY\|X-API-Key\|verify_auth" backend/ --include="*.py"
```

Expected: no matches. If any remain, remove them.

- [ ] **Step 2: Manual smoke test against the dev server**

```bash
cd backend && ANTHROPIC_API_KEY=<your-key> uvicorn app.main:app --reload &
sleep 2
curl -s -X POST localhost:8000/api/auth/signup -H 'Content-Type: application/json' \
  -d '{"email":"andrew@example.com","password":"password123"}'
```

Expected: `{"token":"...","email":"andrew@example.com"}`. Then with that token:

```bash
curl -s localhost:8000/api/queue -H "Authorization: Bearer <token>"
```

Expected: `[]`. Stop the server afterwards.

- [ ] **Step 3: Update README**

In `README.md`, update the dev startup section: add `psql mandarinreader < backend/migrations/003_users_auth.sql` after migration 001, note `ANTHROPIC_API_KEY` env var is now required by the backend (not the extension), remove mentions of entering API key/backend URL in extension options, and add a note: *"The static web dashboard (`backend/static/index.html`) predates accounts and does not yet send auth headers — known limitation."*

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: update dev setup for accounts and server-side Claude key"
```

---

### Task 8: Extension — config, background rewrite, manifest

**Files:**
- Create: `extension/config.js`
- Rewrite: `extension/background.js`
- Modify: `extension/manifest.json`
- Delete: `extension/options.html`, `extension/options.js`

- [ ] **Step 1: Create config.js**

`extension/config.js`:

```js
// Backend origin. Flip to the deployed URL at release time — this is the
// only place it appears.
const BACKEND_URL = "http://localhost:8000";
```

- [ ] **Step 2: Rewrite background.js**

Replace `extension/background.js` entirely:

```js
// MandarinReader background service worker
// All state is persisted in chrome.storage (MV3 service workers are ephemeral).
// Claude analysis happens server-side — this worker only relays page text.

importScripts("config.js");

const PAGE_TEXT_LIMIT = 8000;

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === "captureCurrentPage") {
    handleCapture(request.tabId)
      .then(sendResponse)
      .catch((err) => sendResponse({ success: false, error: err.message }));
    return true; // keep message channel open for async response
  }
});

async function handleCapture(tabId) {
  const { authToken } = await chrome.storage.local.get("authToken");
  if (!authToken) {
    return { success: false, needsAuth: true, error: "Please sign in first." };
  }

  // 1. Extract visible text from the page
  let pageData;
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId },
      func: extractPageData,
    });
    pageData = results[0].result;
  } catch (e) {
    return {
      success: false,
      error: "Cannot read this page. Try a regular http/https page.",
    };
  }

  if (!pageData.text || pageData.text.trim().length < 10) {
    return { success: false, error: "No readable text found on this page." };
  }

  // 2. Send to the backend, which calls Claude and ingests the words
  let resp;
  try {
    resp = await fetch(`${BACKEND_URL}/api/ingest`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${authToken}`,
      },
      body: JSON.stringify({
        url: pageData.url,
        title: pageData.title,
        page_text: pageData.text,
      }),
    });
  } catch (e) {
    return {
      success: false,
      error: `Backend unreachable: ${e.message}. Is the server running?`,
    };
  }

  if (resp.status === 401) {
    await chrome.storage.local.remove(["authToken", "authEmail"]);
    return { success: false, needsAuth: true, error: "Session expired — please sign in again." };
  }
  if (resp.status === 429) {
    return { success: false, error: "Daily capture limit reached — try again tomorrow." };
  }
  if (resp.status === 502) {
    return { success: false, error: "Analysis failed — try again." };
  }
  if (!resp.ok) {
    const text = await resp.text();
    return { success: false, error: `Backend returned ${resp.status}: ${text}` };
  }

  const data = await resp.json();

  // Persist last capture for popup display
  await chrome.storage.local.set({
    lastCapture: {
      timestamp: Date.now(),
      url: pageData.url,
      title: pageData.title,
      page_purpose: data.page_purpose,
      words_added: data.words_added,
      words_updated: data.words_updated,
      total_words: data.total_words,
    },
  });

  return { success: true, ...data };
}

// -----------------------------------------------------------------------
// Injected into the page via chrome.scripting.executeScript
// Must be a standalone function (no closure over outer scope)
// -----------------------------------------------------------------------
function extractPageData() {
  const url = window.location.href;
  const title = document.title;

  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const parent = node.parentElement;
      if (!parent) return NodeFilter.FILTER_REJECT;
      const tag = parent.tagName.toLowerCase();
      if (["script", "style", "noscript", "meta", "head"].includes(tag)) {
        return NodeFilter.FILTER_REJECT;
      }
      try {
        const style = window.getComputedStyle(parent);
        if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") {
          return NodeFilter.FILTER_REJECT;
        }
      } catch (_) {
        // getComputedStyle can throw on detached nodes
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });

  const parts = [];
  let node;
  while ((node = walker.nextNode())) {
    const t = node.textContent.trim();
    if (t) parts.push(t);
  }

  const text = parts.join(" ").replace(/\s+/g, " ").slice(0, 8000);
  return { url, title, text };
}
```

- [ ] **Step 3: Update manifest.json**

Replace `extension/manifest.json`:

```json
{
  "manifest_version": 3,
  "name": "MandarinReader",
  "version": "0.2.0",
  "description": "Capture Traditional Chinese vocabulary from pages you visit and build your personal learning queue.",
  "permissions": [
    "activeTab",
    "storage",
    "scripting",
    "tabs"
  ],
  "host_permissions": [
    "http://localhost:8000/*"
  ],
  "background": {
    "service_worker": "background.js"
  },
  "action": {
    "default_popup": "popup.html",
    "default_icon": {
      "16": "icons/icon16.png",
      "48": "icons/icon48.png",
      "128": "icons/icon128.png"
    },
    "default_title": "MandarinReader — Capture this page"
  }
}
```

> When the backend deploys, add `https://<prod-domain>/*` to `host_permissions`
> alongside flipping `config.js`. `activeTab` + `scripting` still cover text
> extraction on arbitrary pages, so `<all_urls>` is no longer needed.

- [ ] **Step 4: Delete options page**

```bash
git rm extension/options.html extension/options.js
```

- [ ] **Step 5: Commit**

```bash
git add extension/config.js extension/background.js extension/manifest.json
git commit -m "feat(extension): relay page text to backend; remove Claude key and options page"
```

(Popup still references `optionsLink` — fixed in Task 9; the extension isn't loadable-clean until then, which is fine mid-branch.)

---

### Task 9: Extension — popup login/signup UI

**Files:**
- Rewrite: `extension/popup.html`
- Rewrite: `extension/popup.js`

- [ ] **Step 1: Rewrite popup.html**

Replace `extension/popup.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      width: 320px;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 13px;
      background: #fff;
      color: #1a1a1a;
    }
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 12px 14px;
      border-bottom: 1px solid #e5e5e5;
    }
    .header h1 { font-size: 15px; font-weight: 600; }
    .body { padding: 14px; }
    .hidden { display: none !important; }

    /* Auth view */
    #authView input {
      width: 100%;
      padding: 8px 10px;
      margin-bottom: 8px;
      border: 1px solid #ccc;
      border-radius: 6px;
      font-size: 13px;
    }
    #authView input:focus { outline: none; border-color: #c0392b; }
    .primary-btn {
      width: 100%;
      padding: 9px 14px;
      background: #c0392b;
      color: #fff;
      border: none;
      border-radius: 6px;
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
    }
    .primary-btn:hover { background: #a93226; }
    .primary-btn:disabled { background: #ccc; cursor: not-allowed; }
    .auth-toggle {
      margin-top: 10px;
      text-align: center;
      font-size: 12px;
      color: #888;
    }
    .auth-toggle a { color: #c0392b; cursor: pointer; text-decoration: none; }
    #authError { margin-top: 8px; color: #c0392b; font-size: 12px; min-height: 16px; }

    /* Main view */
    #status { margin-top: 10px; color: #555; font-size: 12px; min-height: 18px; }
    #status.error { color: #c0392b; }
    #status.success { color: #27ae60; }
    .last-capture {
      margin-top: 14px;
      padding: 10px 12px;
      background: #f7f7f7;
      border-radius: 6px;
      border: 1px solid #e5e5e5;
    }
    .last-capture .label { font-size: 11px; color: #888; margin-bottom: 4px; }
    .last-capture .purpose { font-size: 12px; color: #333; margin-bottom: 6px; line-height: 1.4; }
    .last-capture .stats { font-size: 11px; color: #555; }
    .last-capture .stats span {
      display: inline-block;
      background: #e8f5e9;
      color: #2e7d32;
      padding: 1px 6px;
      border-radius: 10px;
      margin-right: 4px;
    }
    .last-capture .stats span.updated { background: #e3f2fd; color: #1565c0; }
    .footer {
      margin-top: 14px;
      padding-top: 10px;
      border-top: 1px solid #eee;
      display: flex;
      justify-content: space-between;
      font-size: 11px;
      color: #888;
    }
    .footer a { color: #c0392b; cursor: pointer; text-decoration: none; }
  </style>
</head>
<body>
  <div class="header">
    <h1>MandarinReader</h1>
  </div>

  <!-- Signed-out view -->
  <div class="body hidden" id="authView">
    <input type="email" id="email" placeholder="Email" autocomplete="email">
    <input type="password" id="password" placeholder="Password (min 8 characters)" autocomplete="current-password">
    <button class="primary-btn" id="authBtn">Sign In</button>
    <div id="authError"></div>
    <div class="auth-toggle" id="authToggle">
      No account? <a id="toggleLink">Create one</a>
    </div>
  </div>

  <!-- Signed-in view -->
  <div class="body hidden" id="mainView">
    <button class="primary-btn" id="captureBtn">Capture This Page</button>
    <div id="status"></div>
    <div id="lastCapture"></div>
    <div class="footer">
      <span id="userEmail"></span>
      <a id="signOutLink">Sign out</a>
    </div>
  </div>

  <script src="config.js"></script>
  <script src="popup.js"></script>
</body>
</html>
```

- [ ] **Step 2: Rewrite popup.js**

Replace `extension/popup.js`:

```js
document.addEventListener("DOMContentLoaded", async () => {
  const authView = document.getElementById("authView");
  const mainView = document.getElementById("mainView");
  const authBtn = document.getElementById("authBtn");
  const authError = document.getElementById("authError");
  const toggleLink = document.getElementById("toggleLink");
  const authToggle = document.getElementById("authToggle");
  const emailInput = document.getElementById("email");
  const passwordInput = document.getElementById("password");
  const captureBtn = document.getElementById("captureBtn");
  const statusEl = document.getElementById("status");
  const lastCaptureEl = document.getElementById("lastCapture");
  const userEmailEl = document.getElementById("userEmail");

  let mode = "login"; // or "signup"

  await refreshView();

  // --- Auth ---

  toggleLink.addEventListener("click", () => {
    mode = mode === "login" ? "signup" : "login";
    authBtn.textContent = mode === "login" ? "Sign In" : "Create Account";
    authToggle.innerHTML =
      mode === "login"
        ? 'No account? <a id="toggleLink2">Create one</a>'
        : 'Have an account? <a id="toggleLink2">Sign in</a>';
    document.getElementById("toggleLink2").addEventListener("click", () => toggleLink.click());
    authError.textContent = "";
  });

  authBtn.addEventListener("click", async () => {
    const email = emailInput.value.trim();
    const password = passwordInput.value;
    if (!email || !email.includes("@")) {
      authError.textContent = "Enter a valid email address.";
      return;
    }
    if (password.length < 8) {
      authError.textContent = "Password must be at least 8 characters.";
      return;
    }

    authBtn.disabled = true;
    authError.textContent = "";
    try {
      const resp = await fetch(`${BACKEND_URL}/api/auth/${mode === "login" ? "login" : "signup"}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, password }),
      });
      if (resp.status === 401) {
        authError.textContent = "Invalid email or password.";
      } else if (resp.status === 409) {
        authError.textContent = "An account with this email already exists.";
      } else if (!resp.ok) {
        authError.textContent = `Error ${resp.status} — try again.`;
      } else {
        const data = await resp.json();
        await chrome.storage.local.set({ authToken: data.token, authEmail: data.email });
        passwordInput.value = "";
        await refreshView();
      }
    } catch (e) {
      authError.textContent = "Backend unreachable — is the server running?";
    }
    authBtn.disabled = false;
  });

  document.getElementById("signOutLink").addEventListener("click", async () => {
    const { authToken } = await chrome.storage.local.get("authToken");
    if (authToken) {
      // Best effort — revoke server-side, ignore failures
      fetch(`${BACKEND_URL}/api/auth/logout`, {
        method: "POST",
        headers: { Authorization: `Bearer ${authToken}` },
      }).catch(() => {});
    }
    await chrome.storage.local.remove(["authToken", "authEmail"]);
    await refreshView();
  });

  // --- Capture ---

  captureBtn.addEventListener("click", async () => {
    captureBtn.disabled = true;
    setStatus("Analyzing page…", "");

    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const result = await chrome.runtime.sendMessage({
      action: "captureCurrentPage",
      tabId: tab.id,
    });

    if (result.success) {
      setStatus(`Done! +${result.words_added} new · ${result.words_updated} updated`, "success");
      const fresh = await chrome.storage.local.get("lastCapture");
      if (fresh.lastCapture) renderLastCapture(fresh.lastCapture);
    } else if (result.needsAuth) {
      await refreshView();
      authError.textContent = result.error;
    } else {
      setStatus(result.error, "error");
    }

    captureBtn.disabled = false;
  });

  // --- Helpers ---

  async function refreshView() {
    const { authToken, authEmail, lastCapture } = await chrome.storage.local.get([
      "authToken", "authEmail", "lastCapture",
    ]);
    if (authToken) {
      authView.classList.add("hidden");
      mainView.classList.remove("hidden");
      userEmailEl.textContent = authEmail || "";
      if (lastCapture) renderLastCapture(lastCapture);
    } else {
      mainView.classList.add("hidden");
      authView.classList.remove("hidden");
    }
  }

  function setStatus(msg, type) {
    statusEl.textContent = msg;
    statusEl.className = type;
  }

  function renderLastCapture(lc) {
    const age = formatAge(lc.timestamp);
    lastCaptureEl.innerHTML = `
      <div class="last-capture">
        <div class="label">Last capture · ${age}</div>
        <div class="purpose">${escHtml(lc.page_purpose || "—")}</div>
        <div class="stats">
          <span>+${lc.words_added} new</span>
          <span class="updated">~${lc.words_updated} updated</span>
          of ${lc.total_words} extracted
        </div>
      </div>`;
  }

  function formatAge(ts) {
    const mins = Math.round((Date.now() - ts) / 60000);
    if (mins < 1) return "just now";
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.round(mins / 60);
    return hrs < 24 ? `${hrs}h ago` : `${Math.round(hrs / 24)}d ago`;
  }

  function escHtml(str) {
    return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
});
```

- [ ] **Step 3: Manual verification**

With the backend running (`ANTHROPIC_API_KEY=<key> uvicorn app.main:app --reload` from `backend/`):

1. Chrome → `chrome://extensions` → Reload the unpacked extension (fix any load errors).
2. Open popup → shows sign-in form. Create an account → switches to capture view with email in footer.
3. Visit a Traditional Chinese page (e.g. https://zh.wikipedia.org/zh-tw/貓) → Capture This Page → expect "Done! +N new".
4. Sign out → form returns. Sign back in → capture view persists across popup close/reopen.

- [ ] **Step 4: Commit**

```bash
git add extension/popup.html extension/popup.js
git commit -m "feat(extension): login/signup in popup"
```

---

### Task 10: iOS — AppConfig, TokenStorage, APIClient auth

**Files:**
- Create: `ios/MandarinReader/MandarinReader/App/AppConfig.swift`
- Create: `ios/MandarinReader/MandarinReader/App/TokenStorage.swift`
- Modify: `ios/MandarinReader/MandarinReader/Networking/APIClient.swift`
- Modify: `ios/MandarinReader/MandarinReaderTests/APIClientTests.swift` (add tests; update existing ones from `apiKey:` to `token:`)

All iOS test runs use:

```bash
xcodebuild test -project ios/MandarinReader/MandarinReader.xcodeproj \
  -scheme MandarinReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MandarinReaderTests 2>&1 | tail -25
```

- [ ] **Step 1: Create AppConfig and TokenStorage**

`ios/MandarinReader/MandarinReader/App/AppConfig.swift`:

```swift
import Foundation

enum AppConfig {
    /// Backend origin. Flip to the deployed URL at release time — this is
    /// the only place it appears.
    static let baseURL = URL(string: "http://localhost:8000")!
}
```

`ios/MandarinReader/MandarinReader/App/TokenStorage.swift`:

```swift
import Foundation
import Security

/// Persists the auth token (Keychain) and account email (UserDefaults —
/// not secret). Protocol so tests can use an in-memory store.
protocol TokenStorage {
    func save(token: String, email: String)
    func load() -> (token: String, email: String)?
    func clear()
}

struct KeychainTokenStorage: TokenStorage {
    private static let service = "com.mandarinreader.auth"
    private static let account = "authToken"
    private static let emailKey = "auth.email"

    func save(token: String, email: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(insert as CFDictionary, nil)
        UserDefaults.standard.set(email, forKey: Self.emailKey)
    }

    func load() -> (token: String, email: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        let email = UserDefaults.standard.string(forKey: Self.emailKey) ?? ""
        return (token, email)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
    }
}

final class InMemoryTokenStorage: TokenStorage {
    private var stored: (token: String, email: String)?
    init(token: String? = nil, email: String = "") {
        if let token { stored = (token, email) }
    }
    func save(token: String, email: String) { stored = (token, email) }
    func load() -> (token: String, email: String)? { stored }
    func clear() { stored = nil }
}
```

- [ ] **Step 2: Write failing APIClient tests**

Add to `ios/MandarinReader/MandarinReaderTests/APIClientTests.swift` (follow the file's existing `URLProtocolMock` setup pattern for constructing the mocked `URLSession`):

```swift
func test_login_postsCredentialsAndDecodesToken() async throws {
    URLProtocolMock.requestHandler = { request in
        XCTAssertEqual(request.url?.path, "/api/auth/login")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = #"{"token": "tok123", "email": "a@x.com"}"#.data(using: .utf8)!
        return (response, body)
    }
    let client = APIClient(baseURL: URL(string: "http://test")!, token: nil, session: mockedSession)
    let auth = try await client.login(email: "a@x.com", password: "password123")
    XCTAssertEqual(auth.token, "tok123")
    XCTAssertEqual(auth.email, "a@x.com")
}

func test_signup_conflictThrowsEmailTaken() async {
    URLProtocolMock.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    let client = APIClient(baseURL: URL(string: "http://test")!, token: nil, session: mockedSession)
    do {
        _ = try await client.signup(email: "a@x.com", password: "password123")
        XCTFail("expected emailTaken")
    } catch {
        XCTAssertEqual(error as? APIError, .emailTaken)
    }
}

func test_fetchQueue_sendsBearerToken() async throws {
    URLProtocolMock.requestHandler = { request in
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, "[]".data(using: .utf8)!)
    }
    let client = APIClient(baseURL: URL(string: "http://test")!, token: "tok123", session: mockedSession)
    let items = try await client.fetchQueue(count: 5)
    XCTAssertTrue(items.isEmpty)
}
```

Also update the file's existing tests: every `APIClient(baseURL:apiKey:session:)` call becomes `APIClient(baseURL:token:session:)`, and any assertion on the `X-API-Key` header becomes an assertion on `Authorization: Bearer <value>`.

- [ ] **Step 3: Run to verify failure**

Run the xcodebuild command above. Expected: compile FAILURE (no `token:` initializer, no `login`).

- [ ] **Step 4: Update APIClient**

In `ios/MandarinReader/MandarinReader/Networking/APIClient.swift`:

Extend `APIError`:

```swift
enum APIError: Error, Equatable {
    case unauthorized
    case emailTaken
    case rateLimited
    case httpError(status: Int)
    case invalidResponse
}
```

Change the stored property and init (token optional — auth calls don't need one):

```swift
final class APIClient {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.encoder = JSONEncoder()
    }

    private func authorizedRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
```

Replace the `X-API-Key` lines in `fetchQueue`/`submitReview` with `authorizedRequest` (for `fetchQueue`, build the request from the components URL then apply the same Bearer header logic, or set the header via `if let token`).

Add auth methods and response model:

```swift
struct AuthResponse: Decodable, Equatable {
    let token: String
    let email: String
}

private struct CredentialsBody: Encodable {
    let email: String
    let password: String
}

extension APIClient {
    func signup(email: String, password: String) async throws -> AuthResponse {
        try await authCall(path: "api/auth/signup", email: email, password: password)
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await authCall(path: "api/auth/login", email: email, password: password)
    }

    func logout() async throws {
        let request = authorizedRequest(path: "api/auth/logout", method: "POST")
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    private func authCall(path: String, email: String, password: String) async throws -> AuthResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(CredentialsBody(email: email, password: password))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try decoder.decode(AuthResponse.self, from: data)
    }
}
```

Update `validate` to map the new statuses:

```swift
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        case 409: throw APIError.emailTaken
        case 429: throw APIError.rateLimited
        default: throw APIError.httpError(status: http.statusCode)
        }
    }
```

- [ ] **Step 5: Fix remaining compile errors**

`AppSettings.makeAPIClient()` still calls `APIClient(baseURL:apiKey:)` — change it to `APIClient(baseURL: url, token: apiKey)` as a temporary shim (AppSettings is deleted in Task 11).

- [ ] **Step 6: Run tests**

Run the xcodebuild command. Expected: `** TEST SUCCEEDED **` (new tests pass; existing suites still green).

- [ ] **Step 7: Commit**

```bash
git add ios/
git commit -m "feat(ios): bearer-token APIClient with signup/login/logout"
```

---

### Task 11: iOS — AuthStore, LoginView, view rewiring

**Files:**
- Create: `ios/MandarinReader/MandarinReader/App/AuthStore.swift`
- Create: `ios/MandarinReader/MandarinReader/App/LoginView.swift`
- Create: `ios/MandarinReader/MandarinReaderTests/AuthStoreTests.swift`
- Modify: `ios/MandarinReader/MandarinReader/MandarinReaderApp.swift`
- Modify: `ios/MandarinReader/MandarinReader/Views/StartSessionView.swift`
- Modify: `ios/MandarinReader/MandarinReader/App/SettingsView.swift`
- Delete: `ios/MandarinReader/MandarinReader/App/AppSettings.swift`
- Delete: `ios/MandarinReader/MandarinReaderTests/AppSettingsTests.swift`

- [ ] **Step 1: Write failing AuthStore tests**

`ios/MandarinReader/MandarinReaderTests/AuthStoreTests.swift`:

```swift
import XCTest
@testable import MandarinReader

@MainActor
final class AuthStoreTests: XCTestCase {

    func test_initLoadsPersistedToken() {
        let storage = InMemoryTokenStorage(token: "tok123", email: "a@x.com")
        let store = AuthStore(storage: storage)
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.email, "a@x.com")
    }

    func test_initWithEmptyStorageIsSignedOut() {
        let store = AuthStore(storage: InMemoryTokenStorage())
        XCTAssertFalse(store.isSignedIn)
    }

    func test_handleUnauthorizedClearsState() {
        let storage = InMemoryTokenStorage(token: "tok123", email: "a@x.com")
        let store = AuthStore(storage: storage)
        store.handleUnauthorized()
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(storage.load())
    }

    func test_signInPersistsToken() async throws {
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"token": "fresh", "email": "a@x.com"}"#.data(using: .utf8)!
            return (response, body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        let storage = InMemoryTokenStorage()
        let store = AuthStore(storage: storage, urlSession: URLSession(configuration: config))

        try await store.signIn(email: "a@x.com", password: "password123")

        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(storage.load()?.token, "fresh")
    }
}
```

(Per the project's Xcode 26 conventions: no second ObservableObject against shared UserDefaults; `InMemoryTokenStorage` keeps these tests off the real Keychain.)

- [ ] **Step 2: Run to verify failure**

Run the xcodebuild command from Task 10. Expected: compile FAILURE (`AuthStore` unknown).

- [ ] **Step 3: Create AuthStore**

`ios/MandarinReader/MandarinReader/App/AuthStore.swift`:

```swift
import Combine
import Foundation

/// Observable auth state. Replaces AppSettings — the backend URL is now a
/// compile-time constant (AppConfig) and credentials are a Keychain token.
@MainActor
final class AuthStore: ObservableObject {

    @Published private(set) var token: String?
    @Published private(set) var email: String?

    private let storage: TokenStorage
    private let urlSession: URLSession

    init(storage: TokenStorage = KeychainTokenStorage(), urlSession: URLSession = .shared) {
        self.storage = storage
        self.urlSession = urlSession
        let saved = storage.load()
        self.token = saved?.token
        self.email = saved?.email
    }

    // Required by this project's Xcode 26 setup: @MainActor classes need an
    // explicit nonisolated deinit or tests crash in the back-deployed shim.
    nonisolated deinit { }

    var isSignedIn: Bool { token != nil }

    func makeAPIClient() -> APIClient {
        APIClient(baseURL: AppConfig.baseURL, token: token, session: urlSession)
    }

    func signIn(email: String, password: String) async throws {
        apply(try await makeAPIClient().login(email: email, password: password))
    }

    func signUp(email: String, password: String) async throws {
        apply(try await makeAPIClient().signup(email: email, password: password))
    }

    func signOut() {
        let client = makeAPIClient()
        Task { try? await client.logout() }  // best-effort server-side revocation
        storage.clear()
        token = nil
        email = nil
    }

    /// Call when any API request returns 401 — the session was revoked or expired.
    func handleUnauthorized() {
        storage.clear()
        token = nil
        email = nil
    }

    private func apply(_ auth: AuthResponse) {
        storage.save(token: auth.token, email: auth.email)
        token = auth.token
        email = auth.email
    }
}
```

- [ ] **Step 4: Create LoginView**

`ios/MandarinReader/MandarinReader/App/LoginView.swift`:

```swift
import SwiftUI

struct LoginView: View {

    @EnvironmentObject private var auth: AuthStore

    @State private var email = ""
    @State private var password = ""
    @State private var isSigningUp = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("MandarinReader")
                .font(.system(size: 36, weight: .bold))
            Text(isSigningUp ? "Create your account" : "Sign in to continue")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password (min 8 characters)", text: $password)
                    .textContentType(isSigningUp ? .newPassword : .password)
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: submit) {
                HStack {
                    if isBusy { ProgressView().tint(.white) }
                    Text(isSigningUp ? "Create Account" : "Sign In")
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: 360)
                .padding()
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isBusy)

            Button(isSigningUp ? "Have an account? Sign in" : "No account? Create one") {
                isSigningUp.toggle()
                errorMessage = nil
            }
            .font(.callout)

            Spacer()
        }
        .padding()
    }

    private func submit() {
        guard email.contains("@") else {
            errorMessage = "Enter a valid email address"
            return
        }
        guard password.count >= 8 else {
            errorMessage = "Password must be at least 8 characters"
            return
        }
        errorMessage = nil
        isBusy = true
        Task {
            do {
                if isSigningUp {
                    try await auth.signUp(email: email, password: password)
                } else {
                    try await auth.signIn(email: email, password: password)
                }
            } catch APIError.unauthorized {
                errorMessage = "Invalid email or password"
            } catch APIError.emailTaken {
                errorMessage = "An account with this email already exists"
            } catch {
                errorMessage = "Could not reach the server — try again"
            }
            isBusy = false
        }
    }
}

#Preview {
    LoginView().environmentObject(AuthStore(storage: InMemoryTokenStorage()))
}
```

- [ ] **Step 5: Rewire the app entry point**

Replace `ios/MandarinReader/MandarinReader/MandarinReaderApp.swift`:

```swift
import SwiftUI

@main
struct MandarinReaderApp: App {

    @StateObject private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            if auth.isSignedIn {
                StartSessionView()
                    .environmentObject(auth)
            } else {
                LoginView()
                    .environmentObject(auth)
            }
        }
    }
}
```

- [ ] **Step 6: Update StartSessionView**

In `ios/MandarinReader/MandarinReader/Views/StartSessionView.swift`:

- Replace `@EnvironmentObject private var settings: AppSettings` with `@EnvironmentObject private var auth: AuthStore`.
- Replace every `settings.isConfigured` with `true` semantics — i.e. delete the `!settings.isConfigured` disable conditions, the gray-background ternary (`settings.isConfigured ? Color.accentColor : Color.gray` → `Color.accentColor`), and the "Configure backend URL and API key in Settings first" caption.
- Replace both `guard let client = settings.makeAPIClient() else { ... }` blocks with `let client = auth.makeAPIClient()` (no guard needed — it never fails now).
- In `startSession()`'s `catch APIError.unauthorized` block, replace `errorMessage = "Invalid API key"` with:

```swift
            } catch APIError.unauthorized {
                await MainActor.run {
                    isLoading = false
                    auth.handleUnauthorized()  // returns the app to LoginView
                }
            }
```

- In the `#Preview`, replace `.environmentObject(AppSettings())` with `.environmentObject(AuthStore(storage: InMemoryTokenStorage()))`.

- [ ] **Step 7: Update SettingsView**

Replace the `Form` contents of `ios/MandarinReader/MandarinReader/App/SettingsView.swift` (swap `@EnvironmentObject private var settings: AppSettings` for `@EnvironmentObject private var auth: AuthStore`):

```swift
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: auth.email ?? "—")
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                        dismiss()
                    }
                }

                Section("About") {
                    Text("Stroke order data from Hanzi Writer / Make Me a Hanzi, derived from Arphic Technology fonts under the Arphic Public License (ARPHICPL.TXT is included in the app bundle).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
```

Update its `#Preview` to `.environmentObject(AuthStore(storage: InMemoryTokenStorage()))`.

- [ ] **Step 8: Delete AppSettings**

```bash
git rm ios/MandarinReader/MandarinReader/App/AppSettings.swift \
       ios/MandarinReader/MandarinReaderTests/AppSettingsTests.swift
```

Then grep for stragglers:

```bash
grep -rn "AppSettings\|apiKey" ios/MandarinReader/MandarinReader ios/MandarinReader/MandarinReaderTests
```

Expected: no remaining references (fix any that appear).

- [ ] **Step 9: Run the full iOS test suite**

Run the xcodebuild command from Task 10. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 10: Manual verification in simulator**

With the backend running locally: launch the app in the iPhone 17 Pro simulator (`xcodebuild ... build` or via the iOS Simulator tools), sign up, confirm the practice screen loads the queue (capture a page via the extension first so the queue is non-empty), sign out from Settings, confirm return to LoginView. If requests to `http://localhost:8000` fail with an App Transport Security error, add `NSAppTransportSecurity` → `NSAllowsLocalNetworking: YES` to the target's Info settings.

- [ ] **Step 11: Commit**

```bash
git add ios/
git commit -m "feat(ios): Keychain-backed login flow replacing manual URL/key settings"
```

---

### Task 12: Final verification

- [ ] **Step 1: Full backend suite**

```bash
cd backend && pytest -v
```

Expected: all tests pass.

- [ ] **Step 2: Full iOS suite**

Run the xcodebuild command from Task 10. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: End-to-end walkthrough**

1. Fresh DB state: `dropdb mandarinreader && createdb mandarinreader && psql mandarinreader < backend/migrations/001_initial_schema.sql && python backend/migrations/002_load_cedict.py && psql mandarinreader < backend/migrations/003_users_auth.sql`
2. Start backend with `ANTHROPIC_API_KEY` set.
3. Extension: sign up → capture a Chinese page → words appear.
4. iOS: sign in with the same account → practice session shows the captured words.
5. Second account in the extension → empty queue (isolation, for real this time).

- [ ] **Step 4: Confirm clean tree and log**

```bash
git status && git log --oneline main..HEAD
```

Expected: clean tree; one commit per task.

---

## Self-Review Notes

- Spec coverage: data model/migration (Task 2), auth endpoints + sliding sessions (Tasks 3–4), per-user scoping incl. isolation tests (Task 5), server-side Claude + rate limit + 502 (Task 6), extension (Tasks 8–9), iOS incl. Keychain + Xcode 26 gotchas (Tasks 10–11), error-handling table covered across Tasks 6/8/9/10/11, README (Task 7).
- Known deviation from spec: none. Known limitation carried into README: static web dashboard doesn't authenticate yet.
- Transaction footgun (`async with db.begin()` vs. dependency-held transactions) is handled explicitly in Tasks 4–6.
