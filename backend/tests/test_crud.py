from datetime import datetime, timezone

from sqlalchemy import func, select

from app.crud import upsert_word
from app.models import Encounter, User, Word


async def _make_user(db) -> int:
    user = User(email="a@x.com", password_hash="x", created_at=datetime.now(timezone.utc))
    db.add(user)
    await db.flush()
    return user.id


async def test_upsert_word_recovers_when_concurrent_insert_wins(db, monkeypatch):
    """Simulate the race: our locked select misses (the other ingest hadn't
    committed yet), but by insert time the row exists -> unique violation.
    upsert_word must fall back to the existing-word path instead of 500ing."""
    user_id = await _make_user(db)
    await upsert_word(db, user_id, "貓", "extension_page", "https://a.com", "貓在睡")
    await db.commit()

    real_execute = db.execute
    calls = {"n": 0}

    async def first_select_misses(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            return type("Miss", (), {"scalar_one_or_none": staticmethod(lambda: None)})()
        return await real_execute(*args, **kwargs)

    monkeypatch.setattr(db, "execute", first_select_misses)

    word, is_new = await upsert_word(db, user_id, "貓", "manual_paste", "https://b.com", "貓跑了")
    await db.commit()
    monkeypatch.undo()

    assert is_new is False
    assert word.encounter_count == 2
    assert word.source_diversity_count == 2
    assert (await db.scalar(select(func.count(Word.id)))) == 1
    assert (await db.scalar(select(func.count(Encounter.id)))) == 2
