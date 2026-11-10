import pytest
from sqlalchemy import func, select

from app.models import User, Word
from app.services.starter_deck import load_hsk1, seed_starter_deck

SIGNUP = {"email": "learner@example.com", "password": "password123"}


def test_hsk1_list_is_complete_and_traditional():
    words = load_hsk1()
    assert len(words) == 150
    trads = [w["traditional"] for w in words]
    assert len(set(trads)) == 150
    # Taiwan-standard forms, not the Simplified ones.
    for t in ("愛", "電腦", "裡", "幾", "歲", "聽", "後面", "怎麼"):
        assert t in trads
    for w in words:
        assert w["pinyin"] and w["definition"]


@pytest.mark.starter_deck
async def test_signup_seeds_hsk1_into_queue(client, db):
    signup = await client.post("/api/auth/signup", json=SIGNUP)
    headers = {"Authorization": f"Bearer {signup.json()['token']}"}

    user_id = await db.scalar(select(User.id).where(User.email == SIGNUP["email"]))
    count = await db.scalar(
        select(func.count()).select_from(Word).where(Word.user_id == user_id, Word.hsk_tier == 1)
    )
    assert count == 150

    queue = await client.get("/api/queue?n=5", headers=headers)
    assert queue.status_code == 200
    items = queue.json()
    assert len(items) == 5
    # Stable list order for ties: the file starts 愛, 八, 爸爸 ...
    assert [i["traditional"] for i in items[:3]] == ["愛", "八", "爸爸"]
    assert items[0]["pinyin"] == "ai4" and items[0]["definition"]


@pytest.mark.starter_deck
async def test_seed_is_idempotent_and_keeps_existing_words(client, db):
    await client.post("/api/auth/signup", json=SIGNUP)
    user_id = await db.scalar(select(User.id).where(User.email == SIGNUP["email"]))
    word = await db.scalar(select(Word).where(Word.user_id == user_id, Word.traditional == "愛"))
    word.familiarity_score = 2
    await db.commit()

    assert await seed_starter_deck(db, user_id) == 0
    await db.commit()
    db.expire_all()
    word = await db.scalar(select(Word).where(Word.user_id == user_id, Word.traditional == "愛"))
    assert word.familiarity_score == 2
