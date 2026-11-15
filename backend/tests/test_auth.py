import pytest
from datetime import datetime, timedelta, timezone

from sqlalchemy import select, update

from app.models import AuthSession

SIGNUP = {"email": "andrew@example.com", "password": "password123"}


async def test_signup_returns_token(client):
    resp = await client.post("/api/auth/signup", json=SIGNUP)
    assert resp.status_code == 201
    body = resp.json()
    assert body["email"] == "andrew@example.com"
    assert len(body["token"]) >= 40


async def test_signup_normalizes_email_and_rejects_duplicates(client):
    await client.post("/api/auth/signup", json=SIGNUP)
    resp = await client.post(
        "/api/auth/signup", json={"email": "Andrew@Example.COM", "password": "different123"}
    )
    assert resp.status_code == 409


async def test_signup_short_password_rejected(client):
    resp = await client.post("/api/auth/signup", json={"email": "a@x.com", "password": "short"})
    assert resp.status_code == 422


async def test_login_success(client):
    await client.post("/api/auth/signup", json=SIGNUP)
    resp = await client.post("/api/auth/login", json=SIGNUP)
    assert resp.status_code == 200
    assert len(resp.json()["token"]) >= 40


async def test_login_failures_are_generic(client):
    await client.post("/api/auth/signup", json=SIGNUP)
    wrong_pw = await client.post(
        "/api/auth/login", json={"email": SIGNUP["email"], "password": "wrongwrong1"}
    )
    unknown = await client.post(
        "/api/auth/login", json={"email": "nobody@example.com", "password": "password123"}
    )
    assert wrong_pw.status_code == unknown.status_code == 401
    assert wrong_pw.json()["detail"] == unknown.json()["detail"]


async def test_me_requires_and_accepts_token(client):
    anon = await client.get("/api/auth/me")
    assert anon.status_code == 401

    signup = await client.post("/api/auth/signup", json=SIGNUP)
    token = signup.json()["token"]
    me = await client.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200
    assert me.json()["email"] == "andrew@example.com"


async def test_logout_revokes_token(client):
    signup = await client.post("/api/auth/signup", json=SIGNUP)
    headers = {"Authorization": f"Bearer {signup.json()['token']}"}
    assert (await client.post("/api/auth/logout", headers=headers)).status_code == 204
    assert (await client.get("/api/auth/me", headers=headers)).status_code == 401


async def test_expired_session_rejected(client, db):
    signup = await client.post("/api/auth/signup", json=SIGNUP)
    headers = {"Authorization": f"Bearer {signup.json()['token']}"}
    await db.execute(update(AuthSession).values(
        expires_at=datetime.now(timezone.utc) - timedelta(seconds=1)
    ))
    await db.commit()
    assert (await client.get("/api/auth/me", headers=headers)).status_code == 401


async def test_active_session_expiry_slides(client, db):
    signup = await client.post("/api/auth/signup", json=SIGNUP)
    headers = {"Authorization": f"Bearer {signup.json()['token']}"}
    # Simulate a session 10 days into its 30-day window
    stale = datetime.now(timezone.utc) + timedelta(days=20)
    await db.execute(update(AuthSession).values(expires_at=stale))
    await db.commit()

    assert (await client.get("/api/auth/me", headers=headers)).status_code == 200

    sess = (await db.execute(select(AuthSession))).scalar_one()
    await db.refresh(sess)
    assert sess.expires_at > stale + timedelta(days=8)  # slid back to ~now+30d


# --- validation errors must not echo input ---

async def test_validation_error_does_not_echo_password(client):
    secret = "s3cr3t!"  # too short (< 8) → 422
    resp = await client.post("/api/auth/signup", json={"email": "a@x.com", "password": secret})
    assert resp.status_code == 422
    assert secret not in resp.text
    for err in resp.json()["detail"]:
        assert {"loc", "msg", "type"} <= err.keys()
        assert "input" not in err and "ctx" not in err and "url" not in err


async def test_validation_error_with_lone_surrogate_is_422_not_500(client):
    # The \ud800 escape must reach the server unparsed, so send raw bytes.
    raw = b'{"email":"a@x.com","password":"abcdefgh\\ud800"}'
    resp = await client.post(
        "/api/auth/signup", content=raw, headers={"Content-Type": "application/json"}
    )
    assert resp.status_code == 422


# --- session hygiene ---

async def test_login_purges_own_expired_sessions_and_sets_last_used(client, db):
    await client.post("/api/auth/signup", json=SIGNUP)
    other = await client.post(
        "/api/auth/signup", json={"email": "other@example.com", "password": "password123"}
    )
    assert other.status_code == 201
    # Expire every session (both users).
    past = datetime.now(timezone.utc) - timedelta(days=1)
    await db.execute(update(AuthSession).values(expires_at=past))
    await db.commit()

    resp = await client.post("/api/auth/login", json=SIGNUP)
    assert resp.status_code == 200

    db.expire_all()
    sessions = (await db.execute(select(AuthSession))).scalars().all()
    # Remaining: the other user's expired session (untouched — purge is per
    # user) + my fresh one. My own expired signup session is gone.
    assert len(sessions) == 2
    old, new = sorted(sessions, key=lambda s: s.expires_at)
    assert old.expires_at == past
    assert new.expires_at > datetime.now(timezone.utc)
    assert new.user_id != old.user_id
    assert new.last_used_at is not None


@pytest.mark.starter_deck
async def test_delete_account_removes_user_and_all_their_data(client, db):
    from sqlalchemy import func

    from app.models import Encounter, Page, User, Word

    signup = await client.post("/api/auth/signup", json=SIGNUP)
    headers = {"Authorization": f"Bearer {signup.json()['token']}"}
    user_id = await db.scalar(select(User.id).where(User.email == SIGNUP["email"]))
    word_id = await db.scalar(select(Word.id).where(Word.user_id == user_id).limit(1))
    db.add(Encounter(word_id=word_id, source_type="manual_paste", context_sentence="我愛你",
                     encountered_at=datetime.now(timezone.utc)))
    db.add(Page(user_id=user_id, url="https://example.com", captured_at=datetime.now(timezone.utc)))
    await db.commit()

    other = await client.post("/api/auth/signup", json={"email": "other@example.com", "password": "password123"})
    other_headers = {"Authorization": f"Bearer {other.json()['token']}"}

    resp = await client.delete("/api/auth/me", headers=headers)
    assert resp.status_code == 204

    db.expire_all()
    assert await db.scalar(select(func.count()).select_from(User).where(User.id == user_id)) == 0
    assert await db.scalar(select(func.count()).select_from(Word).where(Word.user_id == user_id)) == 0
    assert await db.scalar(select(func.count()).select_from(Page).where(Page.user_id == user_id)) == 0
    assert await db.scalar(select(func.count()).select_from(Encounter).where(Encounter.word_id == word_id)) == 0
    assert await db.scalar(select(func.count()).select_from(AuthSession).where(AuthSession.user_id == user_id)) == 0

    # The old token no longer works, the email can sign up again, and other users are untouched.
    assert (await client.get("/api/auth/me", headers=headers)).status_code == 401
    assert (await client.post("/api/auth/signup", json=SIGNUP)).status_code == 201
    assert (await client.get("/api/auth/me", headers=other_headers)).status_code == 200


async def test_delete_account_requires_auth(client):
    assert (await client.delete("/api/auth/me")).status_code == 401


async def test_signup_without_marker_skips_seed(client, db):
    """Guard for the conftest opt-out: unmarked tests start with an empty corpus."""
    from sqlalchemy import func

    from app.models import Word

    await client.post("/api/auth/signup", json=SIGNUP)
    assert await db.scalar(select(func.count()).select_from(Word)) == 0
