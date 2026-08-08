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
