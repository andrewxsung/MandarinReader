import os
from contextlib import asynccontextmanager
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from .database import engine, Base
from .routers import auth, ingest, queue, review, words
from .routers import study


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Ensure tables exist (schema created via SQL migration, but this is a safety net)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield


app = FastAPI(title="MandarinReader API", version="0.1.0", lifespan=lifespan)

cors_origins = [o.strip() for o in os.getenv("CORS_ORIGINS", "*").split(",")]
app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    # FastAPI's default handler echoes the submitted `input` (e.g. a rejected
    # password) and crashes with a 500 if that input holds a lone surrogate.
    # Return only where/what/why.
    return JSONResponse(
        status_code=422,
        content={"detail": [
            {k: v for k, v in err.items() if k not in ("input", "ctx", "url")}
            for err in exc.errors()
        ]},
    )


app.include_router(auth.router, prefix="/api", tags=["auth"])
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
