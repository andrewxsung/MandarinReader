"""Server-side page analysis via Claude Haiku.

The prompt is moved verbatim from the old extension/background.js — the
extension no longer talks to Anthropic directly.
"""
import json
import os

from anthropic import AsyncAnthropic
from pydantic import BaseModel, ValidationError

CLAUDE_MODEL = "claude-haiku-4-5-20251001"
MAX_TOKENS = 2500


class ExtractedWord(BaseModel):
    word: str
    context_sentence: str | None = None


class PageAnalysis(BaseModel):
    page_purpose: str
    key_words: list[ExtractedWord]


class AnalysisError(Exception):
    """Claude call or response parsing failed."""


PROMPT_TEMPLATE = """You are a Mandarin Chinese vocabulary extraction assistant.

Given the text of a Chinese-language webpage:
1. Write a 1-2 sentence summary of the page's topic and purpose in English.
2. Identify the 20-30 most important Traditional Chinese vocabulary words that a reader needs to understand to comprehend this page. Focus on content words (nouns, verbs, adjectives) that are specific to the topic — not common everyday function words like 的、是、了、在、有.

Rules:
- Output ONLY valid JSON. Do not include markdown, code fences, or any explanation outside the JSON.
- Only include Traditional Chinese words or phrases (1-4 characters each). Do not include English, numbers, or punctuation.
- The context_sentence field must be a short verbatim excerpt from the page text containing the word (max 30 characters).
- If the page contains no meaningful Chinese text, return: {{"page_purpose": "No Chinese content detected", "key_words": []}}

Output format:
{{
  "page_purpose": "<1-2 sentence description of page topic in English>",
  "key_words": [
    {{"word": "<Traditional Chinese word>", "context_sentence": "<verbatim sentence from page containing this word>"}},
    ...
  ]
}}

Page text:
---
{page_text}
---"""

_client: AsyncAnthropic | None = None


def _get_client() -> AsyncAnthropic:
    global _client
    if _client is None:
        # The SDK happily constructs with an empty key and only fails at request
        # time, so check explicitly: a missing key must fail fast and offline.
        if not os.environ.get("ANTHROPIC_API_KEY"):
            raise AnalysisError("ANTHROPIC_API_KEY not configured")
        # Reads ANTHROPIC_API_KEY from the environment. The SDK default timeout
        # is 600s — far too long to hold a request handler open.
        # Stay under Chrome's 30s MV3 fetch limit: no retries; a failure returns 502 and the user retries.
        _client = AsyncAnthropic(timeout=25.0, max_retries=0)
    return _client


def _extract_text(response) -> str:
    """Pull the JSON text out of a Messages API response, rejecting refusals,
    truncated output, and responses with no text blocks."""
    if response.stop_reason == "refusal":
        raise AnalysisError("Claude refused to analyze the page")
    if response.stop_reason == "max_tokens":
        raise AnalysisError("Claude response truncated at max_tokens")
    text = "".join(block.text for block in response.content if block.type == "text")
    if not text:
        raise AnalysisError("Claude response contained no text")
    return text


def parse_analysis(raw: str) -> PageAnalysis:
    # Strip markdown code fences if Claude adds them despite instructions
    cleaned = raw.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("\n", 1)[1] if "\n" in cleaned else cleaned
        cleaned = cleaned.rsplit("```", 1)[0]
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError as exc:
        # Fallback for one-line fences or chatter around the JSON: take the
        # outermost {...} span and try once more.
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start == -1 or end <= start:
            raise AnalysisError(f"unparseable Claude response: {exc}") from exc
        try:
            data = json.loads(cleaned[start:end + 1])
        except json.JSONDecodeError as exc2:
            raise AnalysisError(f"unparseable Claude response: {exc2}") from exc2
    try:
        return PageAnalysis.model_validate(data)
    except ValidationError as exc:
        raise AnalysisError(f"unparseable Claude response: {exc}") from exc


async def analyze_page(page_text: str) -> PageAnalysis:
    try:
        response = await _get_client().messages.create(
            model=CLAUDE_MODEL,
            max_tokens=MAX_TOKENS,
            temperature=0,
            messages=[{"role": "user", "content": PROMPT_TEMPLATE.format(page_text=page_text)}],
        )
    except AnalysisError:
        raise
    except Exception as exc:
        raise AnalysisError(f"Claude API error: {exc}") from exc
    return parse_analysis(_extract_text(response))
