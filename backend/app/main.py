from contextlib import asynccontextmanager
from pathlib import Path
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from .database import engine, Base
from .routers import ingest, queue, review, words
from .routers import study


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Ensure tables exist (schema created via SQL migration, but this is a safety net)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield


app = FastAPI(title="MandarinReader API", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # POC only — tighten for production
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(ingest.router, prefix="/api", tags=["ingest"])
app.include_router(queue.router, prefix="/api", tags=["queue"])
app.include_router(review.router, prefix="/api", tags=["review"])
app.include_router(words.router, prefix="/api", tags=["words"])
app.include_router(study.router, prefix="/api", tags=["study"])


@app.get("/health")
async def health():
    return {"status": "ok", "message": "MandarinReader API"}


app.mount(
    "/",
    StaticFiles(directory=Path(__file__).parent.parent / "static", html=True),
    name="static",
)
