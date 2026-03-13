#!/usr/bin/env python3
"""
Simulate what the Chrome extension does:
1. Take page text
2. Call Claude to extract vocabulary
3. POST to /api/ingest

Usage:
  python3 test_ingest.py YOUR_API_KEY
"""
import sys
import json
import urllib.request

BACKEND_URL = "http://localhost:8000"
CLAUDE_URL = "https://api.anthropic.com/v1/messages"
CLAUDE_MODEL = "claude-haiku-4-5-20251001"

PAGE_URL = "https://udn.com/news/story/10785/9368920"
PAGE_TITLE = "經典賽Live／4局上南韓打線三上三下 仍4：0領先澳洲"
PAGE_TEXT = """
經典賽Live／4局上南韓打線三上三下 仍4：0領先澳洲

世界棒球經典賽C組賽事邁入尾聲，今天南韓與澳洲一戰將決定南韓、澳洲和中華隊誰能晉級。
韓國隊大聯盟球員金慧成因手指受傷先坐板凳，熄火的混血好手惠特康（Shay Whitcomb）也沒有先發，
換上韓職好手盧施煥、申珉宰。

中華隊打完所有C組賽程後2勝2敗，澳洲2勝1敗、南韓1勝2敗，若南韓擊敗澳洲將形成三隊2勝2敗互咬局面。
依據WBC賽制，將依序比較失分率（總失分÷守備總出局數）、自責分率、團隊打擊率、抽籤。
中華隊若想晉級，最低條件為南韓贏澳洲，南韓至少拿8分，同時澳洲至少拿3分。

這是不討論延長賽的狀況。即便南韓隊丟掉3分以上，並不代表晉級絕望，
仍存在有些微可能性，就是比賽進入延長，此役由南韓隊先攻。
""".strip()


def call_claude(api_key: str) -> dict:
    prompt = f"""You are a Mandarin Chinese vocabulary extraction assistant.

Given the text of a Chinese-language webpage:
1. Write a 1-2 sentence summary of the page's topic and purpose in English.
2. Identify the 20-30 most important Traditional Chinese vocabulary words that a reader needs to understand to comprehend this page. Focus on content words (nouns, verbs, adjectives) specific to the topic — not common function words like 的、是、了、在、有.

Rules:
- Output ONLY valid JSON. No markdown, code fences, or explanation.
- Only Traditional Chinese words/phrases (1-4 characters). No English, numbers, punctuation.
- context_sentence must be copied verbatim from the page text.
- If no meaningful Chinese text, return: {{"page_purpose": "No Chinese content detected", "key_words": []}}

Output format:
{{
  "page_purpose": "<1-2 sentence description in English>",
  "key_words": [
    {{"word": "<Traditional Chinese>", "context_sentence": "<verbatim sentence from page>"}},
    ...
  ]
}}

Page text:
---
{PAGE_TEXT}
---"""

    body = json.dumps({
        "model": CLAUDE_MODEL,
        "max_tokens": 1500,
        "temperature": 0,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    req = urllib.request.Request(
        CLAUDE_URL,
        data=body,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "anthropic-dangerous-direct-browser-access": "true",
            "content-type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    raw = data["content"][0]["text"].strip()
    return json.loads(raw)


def post_ingest(claude_result: dict) -> dict:
    body = json.dumps({
        "url": PAGE_URL,
        "title": PAGE_TITLE,
        "page_purpose": claude_result["page_purpose"],
        "words": claude_result["key_words"],
        "source_type": "extension_page",
    }).encode()

    req = urllib.request.Request(
        f"{BACKEND_URL}/api/ingest",
        data=body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 test_ingest.py YOUR_CLAUDE_API_KEY")
        sys.exit(1)

    api_key = sys.argv[1]

    print("Calling Claude...")
    result = call_claude(api_key)

    print(f"\nPage purpose: {result['page_purpose']}")
    print(f"\nExtracted {len(result['key_words'])} words:")
    for kw in result["key_words"]:
        print(f"  {kw['word']}")

    print("\nIngesting into backend...")
    ingest_resp = post_ingest(result)
    print(f"  words_added:   {ingest_resp['words_added']}")
    print(f"  words_updated: {ingest_resp['words_updated']}")
    print(f"  page_id:       {ingest_resp['page_id']}")

    print("\nFetching queue...")
    req = urllib.request.Request(f"{BACKEND_URL}/api/queue?n=30")
    with urllib.request.urlopen(req) as resp:
        queue = json.loads(resp.read())

    print(f"\nTop words in your learning queue ({len(queue)} total):")
    print(f"{'Word':<8} {'Pinyin':<18} {'Priority':>8}  Definition")
    print("-" * 72)
    for w in queue:
        pinyin = w['pinyin'] or '—'
        defn = (w['definition'] or '—')[:35]
        print(f"{w['traditional']:<8} {pinyin:<18} {w['priority_score']:>8.1f}  {defn}")
