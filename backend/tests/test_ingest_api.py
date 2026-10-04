from datetime import datetime, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy import select

from app.models import Page, User
from app.services import claude

PAYLOAD = {
    "url": "https://example.com/news",
    "title": "測試",
    "page_text": "這是一篇關於貓和狗的文章。" * 3,
}


def fake_analysis(*words: str):
    async def _fake(page_text: str) -> claude.PageAnalysis:
        return claude.PageAnalysis(
            page_purpose="A test article about pets.",
            key_words=[claude.ExtractedWord(word=w, context_sentence="這是句子") for w in words],
        )
    return _fake


async def _signup(client, email="a@x.com") -> dict:
    resp = await client.post("/api/auth/signup", json={"email": email, "password": "password123"})
    assert resp.status_code == 201
    return {"Authorization": f"Bearer {resp.json()['token']}"}


async def test_ingest_calls_claude_and_stores_words(client, monkeypatch):
    monkeypatch.setattr(claude, "analyze_page", fake_analysis("貓", "狗", "cat123"))
    headers = await _signup(client)

    resp = await client.post("/api/ingest", json=PAYLOAD, headers=headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["words_added"] == 2          # "cat123" filtered by is_cjk
    assert body["words_updated"] == 0
    assert body["page_purpose"] == "A test article about pets."
    assert body["total_words"] == 3

    queue = (await client.get("/api/queue", headers=headers)).json()
    assert sorted(w["traditional"] for w in queue) == ["狗", "貓"]


async def test_ingest_strips_whitespace_from_words(client, monkeypatch):
    monkeypatch.setattr(claude, "analyze_page", fake_analysis(" 貓", "貓"))
    headers = await _signup(client)

    body = (await client.post("/api/ingest", json=PAYLOAD, headers=headers)).json()
    assert body["words_added"] == 1
    assert body["words_updated"] == 1
    queue = (await client.get("/api/queue", headers=headers)).json()
    assert [w["traditional"] for w in queue] == ["貓"]


async def test_ingest_requires_auth(client):
    assert (await client.post("/api/ingest", json=PAYLOAD)).status_code == 401


async def test_ingest_claude_failure_returns_502(client, monkeypatch):
    async def _boom(page_text: str):
        raise claude.AnalysisError("upstream error")
    monkeypatch.setattr(claude, "analyze_page", _boom)
    headers = await _signup(client)

    resp = await client.post("/api/ingest", json=PAYLOAD, headers=headers)
    assert resp.status_code == 502


async def test_ingest_without_api_key_returns_502(client, monkeypatch):
    # Real analyze_page, no key configured (conftest sets ANTHROPIC_API_KEY="").
    monkeypatch.setattr(claude, "_client", None)
    headers = await _signup(client)

    resp = await client.post("/api/ingest", json=PAYLOAD, headers=headers)
    assert resp.status_code == 502


async def test_ingest_rate_limited_at_50_per_day(client, db, monkeypatch):
    monkeypatch.setattr(claude, "analyze_page", fake_analysis("貓"))
    headers = await _signup(client)

    user_id = (await db.execute(select(User.id))).scalar_one()
    now = datetime.now(timezone.utc)
    db.add_all([
        Page(user_id=user_id, url=f"https://x.com/{i}", captured_at=now)
        for i in range(50)
    ])
    await db.commit()

    resp = await client.post("/api/ingest", json=PAYLOAD, headers=headers)
    assert resp.status_code == 429


async def test_ingest_rejects_oversized_text(client):
    headers = await _signup(client)
    too_big = {**PAYLOAD, "page_text": "字" * 8001}
    assert (await client.post("/api/ingest", json=too_big, headers=headers)).status_code == 422


# --- claude service unit tests (no network) ---

async def test_parse_claude_json_strips_code_fences():
    raw = '```json\n{"page_purpose": "p", "key_words": []}\n```'
    analysis = claude.parse_analysis(raw)
    assert analysis.page_purpose == "p"


def test_parse_analysis_plain_json():
    raw = '{"page_purpose": "p", "key_words": [{"word": "貓", "context_sentence": "貓在睡"}]}'
    analysis = claude.parse_analysis(raw)
    assert [w.word for w in analysis.key_words] == ["貓"]


@pytest.mark.parametrize("raw", [
    '```json {"page_purpose": "p", "key_words": []}```',             # one-line fence
    'Here you go:\n```json\n{"page_purpose": "p", "key_words": []}\n```',  # preamble
    'Sure! {"page_purpose": "p", "key_words": []} Hope that helps.',   # bare chatter
])
def test_parse_analysis_tolerates_wrapped_json(raw):
    assert claude.parse_analysis(raw).page_purpose == "p"


def test_claude_client_has_short_timeout_and_retries(monkeypatch):
    seen = {}

    def _fake_client(**kwargs):
        seen.update(kwargs)
        return object()

    monkeypatch.setattr(claude, "_client", None)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-not-a-real-key")
    monkeypatch.setattr(claude, "AsyncAnthropic", _fake_client)
    claude._get_client()
    assert seen == {"timeout": 60.0, "max_retries": 2}


@pytest.mark.parametrize(
    "raw", ["not json", '{"page_purpose": "p"}', "```json\n```", "", "{ broken } {"]
)
def test_parse_analysis_rejects_bad_output(raw):
    with pytest.raises(claude.AnalysisError):
        claude.parse_analysis(raw)


async def test_analyze_page_without_api_key_raises_offline(monkeypatch):
    constructed = []
    monkeypatch.setattr(claude, "_client", None)
    monkeypatch.setattr(claude, "AsyncAnthropic", lambda *a, **kw: constructed.append(1))

    with pytest.raises(claude.AnalysisError, match="ANTHROPIC_API_KEY"):
        await claude.analyze_page("這是一篇文章")
    assert constructed == []  # never built a client, so never touched the network


def _response(stop_reason, *blocks):
    return SimpleNamespace(stop_reason=stop_reason, content=list(blocks))


def _text(text):
    return SimpleNamespace(type="text", text=text)


def test_extract_text_joins_text_blocks():
    resp = _response("end_turn", _text('{"a": '), SimpleNamespace(type="thinking"), _text("1}"))
    assert claude._extract_text(resp) == '{"a": 1}'


@pytest.mark.parametrize("stop_reason", ["refusal", "max_tokens"])
def test_extract_text_rejects_refusal_and_truncation(stop_reason):
    with pytest.raises(claude.AnalysisError):
        claude._extract_text(_response(stop_reason, _text('{"page_purpose": "p"')))


def test_extract_text_rejects_no_text_blocks():
    with pytest.raises(claude.AnalysisError):
        claude._extract_text(_response("end_turn"))
