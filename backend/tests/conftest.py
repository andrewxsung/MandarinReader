import os

# Must be set BEFORE app.database is imported (it reads DATABASE_URL at import time).
os.environ["DATABASE_URL"] = os.environ.get(
    "TEST_DATABASE_URL", "postgresql+asyncpg://localhost/mandarinreader_test"
)
# Tests must never hit the real API. app.database calls load_dotenv(); a *popped*
# var would be re-populated from backend/.env, but load_dotenv doesn't override a
# var that is already set — even to "". Empty (not a dummy key) so code guarded by
# `if api_key:` stays off instead of making a doomed network call.
os.environ["ANTHROPIC_API_KEY"] = ""

import pytest_asyncio  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402

from app.database import AsyncSessionLocal, Base, engine  # noqa: E402
from app.main import app  # noqa: E402


@pytest_asyncio.fixture
async def db_schema():
    """Create all tables before the test, drop after. Slow but isolated.

    Not autouse: pure-unit tests (password hashing, token helpers) shouldn't
    need a running Postgres. Request it via the `client` or `db` fixtures, or
    directly.

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
async def client(db_schema):
    """HTTP client speaking to the app in-process.

    ASGITransport does NOT run the app's lifespan, so main.py's startup
    create_all never fires here — db_schema deliberately substitutes for it.
    """
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest_asyncio.fixture
async def db(db_schema):
    """Direct DB session for test setup/assertions."""
    async with AsyncSessionLocal() as session:
        yield session
