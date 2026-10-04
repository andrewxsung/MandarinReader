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
