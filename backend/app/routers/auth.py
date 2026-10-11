from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from ..auth import SESSION_TTL, bearer_scheme, get_current_user
from ..database import get_db
from ..models import AuthSession, User
from ..schemas import AuthResponse, CredentialsRequest, MeResponse
from ..services.security import hash_password, hash_token, new_token, verify_password

router = APIRouter()

# Verified against when the login email doesn't exist, so an unknown email
# costs the same argon2 work as a wrong password (no account-existence timing leak).
_DUMMY_HASH = hash_password("dummy-password-for-timing")


async def _open_session(db: AsyncSession, user_id: int) -> str:
    token = new_token()
    now = datetime.now(timezone.utc)
    # Opportunistic cleanup: drop this user's dead sessions so the table
    # doesn't grow forever with one row per login.
    await db.execute(
        delete(AuthSession).where(AuthSession.user_id == user_id, AuthSession.expires_at < now)
    )
    db.add(AuthSession(
        user_id=user_id,
        token_hash=hash_token(token),
        created_at=now,
        expires_at=now + SESSION_TTL,
        last_used_at=now,
    ))
    return token


@router.post("/auth/signup", response_model=AuthResponse, status_code=201)
async def signup(payload: CredentialsRequest, db: AsyncSession = Depends(get_db)):
    email = payload.email.lower().strip()
    # argon2 is CPU/memory heavy — keep it off the event loop.
    password_hash = await run_in_threadpool(hash_password, payload.password)

    # No check-then-insert pre-check: it's racy. The users.email unique
    # constraint is the single source of truth for duplicates.
    user = User(
        email=email,
        password_hash=password_hash,
        created_at=datetime.now(timezone.utc),
    )
    try:
        db.add(user)
        await db.flush()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(status_code=409, detail="An account with this email already exists")

    token = await _open_session(db, user.id)
    await db.commit()
    return AuthResponse(token=token, email=email)


@router.post("/auth/login", response_model=AuthResponse)
async def login(payload: CredentialsRequest, db: AsyncSession = Depends(get_db)):
    email = payload.email.lower().strip()
    user = await db.scalar(select(User).where(User.email == email))
    if user is None:
        await run_in_threadpool(verify_password, _DUMMY_HASH, payload.password)
        raise HTTPException(status_code=401, detail="Invalid email or password")
    ok = await run_in_threadpool(verify_password, user.password_hash, payload.password)
    if not ok:
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
