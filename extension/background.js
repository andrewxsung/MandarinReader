// MandarinReader background service worker
// All state is persisted in chrome.storage (MV3 service workers are ephemeral).
// Claude analysis happens server-side — this worker only relays page text.

importScripts("config.js");

const PAGE_TEXT_LIMIT = 8000;

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === "captureCurrentPage") {
    handleCapture(request.tabId)
      .then(sendResponse)
      .catch((err) => sendResponse({ success: false, error: err.message }));
    return true; // keep message channel open for async response
  }
});

async function handleCapture(tabId) {
  const { authToken } = await chrome.storage.local.get("authToken");
  if (!authToken) {
    return { success: false, needsAuth: true, error: "Please sign in first." };
  }

  // 1. Extract visible text from the page
  let pageData;
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId },
      func: extractPageData,
      args: [PAGE_TEXT_LIMIT],
    });
    pageData = results[0].result;
  } catch (e) {
    return {
      success: false,
      error: "Cannot read this page. Try a regular http/https page.",
    };
  }

  if (!pageData || !pageData.text || pageData.text.trim().length < 10) {
    return { success: false, error: "No readable text found on this page." };
  }

  // 2. Send to the backend, which calls Claude and ingests the words
  let resp;
  try {
    resp = await fetch(`${BACKEND_URL}/api/ingest`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${authToken}`,
      },
      body: JSON.stringify({
        url: pageData.url,
        title: pageData.title,
        page_text: pageData.text,
      }),
    });
  } catch (e) {
    return {
      success: false,
      error: `Backend unreachable: ${e.message}. Is the server running?`,
    };
  }

  if (resp.status === 401) {
    await chrome.storage.local.remove(["authToken", "authEmail"]);
    return { success: false, needsAuth: true, error: "Session expired — please sign in again." };
  }
  if (resp.status === 429) {
    return { success: false, error: "Daily capture limit reached — try again tomorrow." };
  }
  if (resp.status === 502) {
    return { success: false, error: "Analysis failed — try again." };
  }
  if (!resp.ok) {
    const text = await resp.text();
    return { success: false, error: `Backend returned ${resp.status}: ${text}` };
  }

  const data = await resp.json();

  // Persist last capture for popup display
  await chrome.storage.local.set({
    lastCapture: {
      timestamp: Date.now(),
      url: pageData.url,
      title: pageData.title,
      page_purpose: data.page_purpose,
      words_added: data.words_added,
      words_updated: data.words_updated,
      total_words: data.total_words,
    },
  });

  return { success: true, ...data };
}

// -----------------------------------------------------------------------
// Injected into the page via chrome.scripting.executeScript
// Must be a standalone function (no closure over outer scope) — the text
// limit is passed in via `args`.
// -----------------------------------------------------------------------
function extractPageData(limit) {
  const url = window.location.href;
  const title = document.title;

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

  const text = parts.join(" ").replace(/\s+/g, " ").slice(0, limit);
  return { url, title, text };
}
