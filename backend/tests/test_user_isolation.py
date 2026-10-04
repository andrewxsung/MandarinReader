from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select

from app.models import Encounter, Page, User, Word


async def _signup(client, email: str) -> dict:
    resp = await client.post("/api/auth/signup", json={"email": email, "password": "password123"})
    return {"Authorization": f"Bearer {resp.json()['token']}"}


async def _user_id(db, email: str) -> int:
    return (await db.execute(select(User.id).where(User.email == email))).scalar_one()


async def _make_word(
    db,
    email: str,
    traditional: str,
    *,
    familiarity_score: int = 0,
    next_review_date: date | None = None,
) -> Word:
    user_id = await _user_id(db, email)
    now = datetime.now(timezone.utc)
    word = Word(
        user_id=user_id, traditional=traditional, familiarity_score=familiarity_score,
        encounter_count=1, source_diversity_count=1, priority_score=1.0,
        ease_factor=2.5, srs_interval_days=1, next_review_date=next_review_date,
        created_at=now, updated_at=now,
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
    headers_b = await _signup(client, "b@x.com")
    # B owns words that WOULD appear in A's study views if they weren't scoped:
    # a known word (free/known_practice) and a learning word due yesterday
    # (free/new_learning and plan).
    await _make_word(db, "b@x.com", "狗", familiarity_score=2)
    await _make_word(
        db, "b@x.com", "鳥", familiarity_score=1,
        next_review_date=date.today() - timedelta(days=1),
    )

    # Sanity: B sees them, so the fixture data qualifies for both endpoints.
    free_b = (await client.get("/api/study/free", headers=headers_b)).json()
    assert [w["traditional"] for w in free_b["known_practice"]] == ["狗"]
    assert [w["traditional"] for w in free_b["new_learning"]] == ["鳥"]
    plan_b = (await client.get("/api/study/plan", headers=headers_b)).json()
    assert [w["traditional"] for w in plan_b["words"]] == ["鳥"]

    # A sees none of B's words.
    free_a = (await client.get("/api/study/free", headers=headers_a)).json()
    assert free_a == {"known_practice": [], "new_learning": []}
    plan_a = (await client.get("/api/study/plan", headers=headers_a)).json()
    assert plan_a["words"] == []


async def test_recent_is_per_user(client, db):
    headers_a = await _signup(client, "a@x.com")
    headers_b = await _signup(client, "b@x.com")
    url = "https://x.com/b"
    now = datetime.now(timezone.utc)

    word_b = await _make_word(db, "b@x.com", "狗")
    db.add(Page(user_id=await _user_id(db, "b@x.com"), url=url, captured_at=now))
    db.add(Encounter(
        word_id=word_b.id, source_type="extension_page",
        source_url=url, encountered_at=now,
    ))
    # A captured the SAME url but has no words from it; B's encounter on that
    # url must not leak into A's recent list.
    db.add(Page(user_id=await _user_id(db, "a@x.com"), url=url, captured_at=now))
    await db.commit()

    recent_b = (await client.get("/api/recent", headers=headers_b)).json()
    assert [w["traditional"] for w in recent_b] == ["狗"]
    recent_a = (await client.get("/api/recent", headers=headers_a)).json()
    assert recent_a == []
