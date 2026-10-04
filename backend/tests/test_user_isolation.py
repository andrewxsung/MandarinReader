from datetime import datetime, timezone

from sqlalchemy import select

from app.models import User, Word


async def _signup(client, email: str) -> dict:
    resp = await client.post("/api/auth/signup", json={"email": email, "password": "password123"})
    return {"Authorization": f"Bearer {resp.json()['token']}"}


async def _make_word(db, email: str, traditional: str) -> Word:
    user_id = (await db.execute(select(User.id).where(User.email == email))).scalar_one()
    now = datetime.now(timezone.utc)
    word = Word(
        user_id=user_id, traditional=traditional, familiarity_score=0,
        encounter_count=1, source_diversity_count=1, priority_score=1.0,
        ease_factor=2.5, srs_interval_days=1, created_at=now, updated_at=now,
    )
    db.add(word)
    await db.commit()
    await db.refresh(word)
    return word


async def test_queue_is_per_user(client, db):
    headers_a = await _signup(client, "a@x.com")
    headers_b = await _signup(client, "b@x.com")
    await _make_word(db, "a@x.com", "貓")
    await _make_word(db, "b@x.com", "狗")

    queue_a = (await client.get("/api/queue", headers=headers_a)).json()
    queue_b = (await client.get("/api/queue", headers=headers_b)).json()
    assert [w["traditional"] for w in queue_a] == ["貓"]
    assert [w["traditional"] for w in queue_b] == ["狗"]


async def test_queue_requires_auth(client):
    assert (await client.get("/api/queue")).status_code == 401


async def test_words_list_is_per_user(client, db):
    headers_a = await _signup(client, "a@x.com")
    await _signup(client, "b@x.com")
    await _make_word(db, "b@x.com", "狗")
    assert (await client.get("/api/words", headers=headers_a)).json() == []


async def test_cannot_review_another_users_word(client, db):
    headers_a = await _signup(client, "a@x.com")
    await _signup(client, "b@x.com")
    word_b = await _make_word(db, "b@x.com", "狗")

    resp = await client.post(
        f"/api/review/{word_b.id}", json={"result": "known"}, headers=headers_a
    )
    assert resp.status_code == 404


async def test_review_own_word_works(client, db):
    headers_a = await _signup(client, "a@x.com")
    word_a = await _make_word(db, "a@x.com", "貓")
    resp = await client.post(
        f"/api/review/{word_a.id}", json={"result": "known"}, headers=headers_a
    )
    assert resp.status_code == 200
    assert resp.json()["familiarity_score"] == 2


async def test_word_lookup_scoped_to_user(client, db):
    headers_a = await _signup(client, "a@x.com")
    await _signup(client, "b@x.com")
    await _make_word(db, "b@x.com", "狗")

    resp = await client.get("/api/word/狗", headers=headers_a)
    # Not in A's corpus and test cedict table is empty → 404
    assert resp.status_code == 404


async def test_study_endpoints_scoped(client, db):
    headers_a = await _signup(client, "a@x.com")
    await _signup(client, "b@x.com")
    await _make_word(db, "b@x.com", "狗")

    free = (await client.get("/api/study/free", headers=headers_a)).json()
    assert free == {"known_practice": [], "new_learning": []}
    plan = (await client.get("/api/study/plan", headers=headers_a)).json()
    assert plan["words"] == []
