// MandarinReader background service worker
// All state is persisted in chrome.storage (MV3 service workers are ephemeral)

const CLAUDE_API_URL = "https://api.anthropic.com/v1/messages";
const CLAUDE_MODEL = "claude-haiku-4-5-20251001";
const PAGE_TEXT_LIMIT = 8000;

// -----------------------------------------------------------------------
// Message handler — popup sends 'captureCurrentPage' to trigger a capture
// -----------------------------------------------------------------------
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === "captureCurrentPage") {
    handleCapture(request.tabId)
      .then(sendResponse)
      .catch((err) => sendResponse({ success: false, error: err.message }));
    return true; // keep message channel open for async response
  }
});

// -----------------------------------------------------------------------
// Main capture flow
// -----------------------------------------------------------------------
async function handleCapture(tabId) {
  const settings = await chrome.storage.sync.get({
    claudeApiKey: "",
    backendUrl: "http://localhost:8000",
    mrApiKey: "",
  });

  if (!settings.claudeApiKey) {
    return {
      success: false,
      error: "No Claude API key set. Click the gear icon to open Options.",
    };
  }

  // 1. Extract visible text from the page
  let pageData;
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId },
      func: extractPageData,
    });
    pageData = results[0].result;
  } catch (e) {
    return {
      success: false,
      error: "Cannot read this page. Try a regular http/https page.",
    };
  }

  if (!pageData.text || pageData.text.trim().length < 10) {
    return { success: false, error: "No readable text found on this page." };
  }

  // 2. Ask Claude to identify page purpose and key vocabulary
  let claudeResult;
  try {
    claudeResult = await callClaude(pageData.text, settings.claudeApiKey);
  } catch (e) {
    return { success: false, error: `Claude API error: ${e.message}` };
  }

  if (!claudeResult.key_words || claudeResult.key_words.length === 0) {
    return {
      success: false,
      error: `Page analysed but no Chinese vocabulary found. Purpose: ${claudeResult.page_purpose}`,
    };
  }

  // 3. Send to MandarinReader backend
  try {
    const resp = await fetch(`${settings.backendUrl}/api/ingest`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(settings.mrApiKey && { "X-API-Key": settings.mrApiKey }),
      },
      body: JSON.stringify({
        url: pageData.url,
        title: pageData.title,
        page_purpose: claudeResult.page_purpose,
        words: claudeResult.key_words,
        source_type: "extension_page",
      }),
    });

    if (!resp.ok) {
      const text = await resp.text();
      throw new Error(`Backend returned ${resp.status}: ${text}`);
    }

    const data = await resp.json();

    // Persist last capture for popup display
    await chrome.storage.local.set({
      lastCapture: {
        timestamp: Date.now(),
        url: pageData.url,
        title: pageData.title,
        page_purpose: claudeResult.page_purpose,
        words_added: data.words_added,
        words_updated: data.words_updated,
        total_words: claudeResult.key_words.length,
      },
    });

    return { success: true, ...data };
  } catch (e) {
    return {
      success: false,
      error: `Backend unreachable: ${e.message}. Is the server running?`,
    };
  }
}

// -----------------------------------------------------------------------
// Injected into the page via chrome.scripting.executeScript
// Must be a standalone function (no closure over outer scope)
// -----------------------------------------------------------------------
function extractPageData() {
  const url = window.location.href;
  const title = document.title;

  // Walk visible text nodes, skip scripts/styles/hidden elements
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const parent = node.parentElement;
      if (!parent) return NodeFilter.FILTER_REJECT;
      const tag = parent.tagName.toLowerCase();
      if (["script", "style", "noscript", "meta", "head"].includes(tag)) {
        return NodeFilter.FILTER_REJECT;
      }
      try {
        const style = window.getComputedStyle(parent);
        if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") {
          return NodeFilter.FILTER_REJECT;
        }
      } catch (_) {
        // getComputedStyle can throw on detached nodes
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });

  const parts = [];
  let node;
  while ((node = walker.nextNode())) {
    const t = node.textContent.trim();
    if (t) parts.push(t);
  }

  const text = parts.join(" ").replace(/\s+/g, " ").slice(0, 8000);
  return { url, title, text };
}

// -----------------------------------------------------------------------
// Claude API call
// -----------------------------------------------------------------------
async function callClaude(pageText, apiKey) {
  const prompt = buildPrompt(pageText);

  const resp = await fetch(CLAUDE_API_URL, {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "anthropic-dangerous-direct-browser-access": "true",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: CLAUDE_MODEL,
      max_tokens: 2500,
      temperature: 0,
      messages: [{ role: "user", content: prompt }],
    }),
  });

  if (!resp.ok) {
    let errMsg = resp.statusText;
    try {
      const errBody = await resp.json();
      errMsg = errBody.error?.message || errMsg;
    } catch (_) {}
    throw new Error(errMsg);
  }

  const data = await resp.json();
  const rawText = data.content[0].text.trim();

  // Strip markdown code fences if Claude adds them despite instructions
  const cleaned = rawText.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");

  return JSON.parse(cleaned);
}

// -----------------------------------------------------------------------
// Prompt builder
// -----------------------------------------------------------------------
function buildPrompt(pageText) {
  return `You are a Mandarin Chinese vocabulary extraction assistant.

Given the text of a Chinese-language webpage:
1. Write a 1-2 sentence summary of the page's topic and purpose in English.
2. Identify the 20-30 most important Traditional Chinese vocabulary words that a reader needs to understand to comprehend this page. Focus on content words (nouns, verbs, adjectives) that are specific to the topic — not common everyday function words like 的、是、了、在、有.

Rules:
- Output ONLY valid JSON. Do not include markdown, code fences, or any explanation outside the JSON.
- Only include Traditional Chinese words or phrases (1-4 characters each). Do not include English, numbers, or punctuation.
- The context_sentence field must be a short verbatim excerpt from the page text containing the word (max 30 characters).
- If the page contains no meaningful Chinese text, return: {"page_purpose": "No Chinese content detected", "key_words": []}

Output format:
{
  "page_purpose": "<1-2 sentence description of page topic in English>",
  "key_words": [
    {"word": "<Traditional Chinese word>", "context_sentence": "<verbatim sentence from page containing this word>"},
    ...
  ]
}

Page text:
---
${pageText}
---`;
}
