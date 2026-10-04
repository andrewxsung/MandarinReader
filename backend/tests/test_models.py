from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import delete, func, select
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
    with pytest.raises(IntegrityError, match="words_user_traditional_key"):
        await db.commit()
    await db.rollback()


async def test_deleting_user_cascades_to_sessions_and_words(db):
    now = datetime.now(timezone.utc)
    a = User(email="a@x.com", password_hash="h", created_at=now)
    db.add(a)
    await db.flush()
    user_id = a.id
    db.add(AuthSession(
        user_id=user_id, token_hash="abc123", created_at=now,
        expires_at=now + timedelta(days=30),
    ))
    db.add(_word(user_id, "貓"))
    await db.commit()

    # Core DELETE (no ORM relationships involved) so this proves the DB-level
    # ON DELETE CASCADE on sessions.user_id and words.user_id.
    await db.execute(delete(User).where(User.id == user_id))
    await db.commit()

    assert await db.scalar(select(func.count()).select_from(AuthSession)) == 0
    assert await db.scalar(select(func.count()).select_from(Word)) == 0
