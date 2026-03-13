document.addEventListener("DOMContentLoaded", async () => {
  const btn = document.getElementById("captureBtn");
  const statusEl = document.getElementById("status");
  const lastCaptureEl = document.getElementById("lastCapture");

  // Open options page
  document.getElementById("optionsLink").addEventListener("click", () => {
    chrome.runtime.openOptionsPage();
  });

  // Show last capture if available
  const stored = await chrome.storage.local.get("lastCapture");
  if (stored.lastCapture) {
    renderLastCapture(stored.lastCapture);
  }

  // Capture button
  btn.addEventListener("click", async () => {
    btn.disabled = true;
    setStatus("Extracting page text…", "");

    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

    setStatus("Asking Claude to identify key vocabulary…", "");

    const result = await chrome.runtime.sendMessage({
      action: "captureCurrentPage",
      tabId: tab.id,
    });

    if (result.success) {
      setStatus(
        `Done! +${result.words_added} new · ${result.words_updated} updated`,
        "success"
      );
      // Refresh last capture display
      const fresh = await chrome.storage.local.get("lastCapture");
      if (fresh.lastCapture) renderLastCapture(fresh.lastCapture);
    } else {
      setStatus(result.error, "error");
    }

    btn.disabled = false;
  });

  function setStatus(msg, type) {
    statusEl.textContent = msg;
    statusEl.className = type;
  }

  function renderLastCapture(lc) {
    const age = formatAge(lc.timestamp);
    lastCaptureEl.innerHTML = `
      <div class="last-capture">
        <div class="label">Last capture · ${age}</div>
        <div class="purpose">${escHtml(lc.page_purpose || "—")}</div>
        <div class="stats">
          <span>+${lc.words_added} new</span>
          <span class="updated">~${lc.words_updated} updated</span>
          of ${lc.total_words} extracted
        </div>
      </div>`;
  }

  function formatAge(ts) {
    const mins = Math.round((Date.now() - ts) / 60000);
    if (mins < 1) return "just now";
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.round(mins / 60);
    return hrs < 24 ? `${hrs}h ago` : `${Math.round(hrs / 24)}d ago`;
  }

  function escHtml(str) {
    return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
});
