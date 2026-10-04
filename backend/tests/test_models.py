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
