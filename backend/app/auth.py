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
