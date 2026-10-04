document.addEventListener("DOMContentLoaded", async () => {
  const authView = document.getElementById("authView");
  const mainView = document.getElementById("mainView");
  const authBtn = document.getElementById("authBtn");
  const authError = document.getElementById("authError");
  const togglePrompt = document.getElementById("togglePrompt");
  const toggleLink = document.getElementById("toggleLink");
  const emailInput = document.getElementById("email");
  const passwordInput = document.getElementById("password");
  const captureBtn = document.getElementById("captureBtn");
  const statusEl = document.getElementById("status");
  const lastCaptureEl = document.getElementById("lastCapture");
  const userEmailEl = document.getElementById("userEmail");

  let mode = "login"; // or "signup"

  await refreshView();

  // --- Auth ---

  toggleLink.addEventListener("click", () => {
    mode = mode === "login" ? "signup" : "login";
    const isLogin = mode === "login";
    authBtn.textContent = isLogin ? "Sign In" : "Create Account";
    togglePrompt.textContent = isLogin ? "No account?" : "Have an account?";
    toggleLink.textContent = isLogin ? "Create one" : "Sign in";
    passwordInput.autocomplete = isLogin ? "current-password" : "new-password";
    authError.textContent = "";
  });

  authBtn.addEventListener("click", submitAuth);
  for (const input of [emailInput, passwordInput]) {
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        submitAuth();
      }
    });
  }

  async function submitAuth() {
    if (authBtn.disabled) return; // a request is already in flight

    const email = emailInput.value.trim();
    const password = passwordInput.value;
    if (!email || !email.includes("@")) {
      authError.textContent = "Enter a valid email address.";
      return;
    }
    if (password.length < 8) {
      authError.textContent = "Password must be at least 8 characters.";
      return;
    }

    authBtn.disabled = true;
    authError.textContent = "";
    try {
      const resp = await fetch(`${BACKEND_URL}/api/auth/${mode === "login" ? "login" : "signup"}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, password }),
      });
      if (resp.status === 401) {
        authError.textContent = "Invalid email or password.";
      } else if (resp.status === 409) {
        authError.textContent = "An account with this email already exists.";
      } else if (resp.status === 422) {
        authError.textContent = "Enter a valid email and a password of at least 8 characters.";
      } else if (!resp.ok) {
        authError.textContent = `Error ${resp.status} — try again.`;
      } else {
        const data = await resp.json();
        await chrome.storage.local.set({ authToken: data.token, authEmail: data.email });
        passwordInput.value = "";
        await refreshView();
      }
    } catch (e) {
      authError.textContent = "Backend unreachable — is the server running?";
    } finally {
      authBtn.disabled = false;
    }
  }

  document.getElementById("signOutLink").addEventListener("click", async () => {
    const { authToken } = await chrome.storage.local.get("authToken");
    if (authToken) {
      // Best effort — revoke server-side, ignore failures
      fetch(`${BACKEND_URL}/api/auth/logout`, {
        method: "POST",
        headers: { Authorization: `Bearer ${authToken}` },
      }).catch(() => {});
    }
    await chrome.storage.local.remove(["authToken", "authEmail", "lastCapture"]);
    await refreshView();
  });

  // --- Capture ---

  captureBtn.addEventListener("click", async () => {
    captureBtn.disabled = true;
    setStatus("Analyzing page…", "");

    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (!tab) {
        setStatus("No active tab found.", "error");
        return;
      }
      const result = await chrome.runtime.sendMessage({
        action: "captureCurrentPage",
        tabId: tab.id,
      });

      if (!result) {
        setStatus("No response from the extension — try again.", "error");
      } else if (result.success) {
        setStatus(`Done! +${result.words_added} new · ${result.words_updated} updated`, "success");
        const fresh = await chrome.storage.local.get("lastCapture");
        if (fresh.lastCapture) renderLastCapture(fresh.lastCapture);
      } else if (result.needsAuth) {
        await refreshView();
        authError.textContent = result.error;
      } else {
        setStatus(result.error, "error");
      }
    } catch (e) {
      setStatus(`Capture failed: ${e.message}`, "error");
    } finally {
      captureBtn.disabled = false;
    }
  });

  // --- Helpers ---

  async function refreshView() {
    const { authToken, authEmail, lastCapture } = await chrome.storage.local.get([
      "authToken", "authEmail", "lastCapture",
    ]);
    if (authToken) {
      authView.classList.add("hidden");
      mainView.classList.remove("hidden");
      userEmailEl.textContent = authEmail || "";
      if (lastCapture) renderLastCapture(lastCapture);
    } else {
      mainView.classList.add("hidden");
      authView.classList.remove("hidden");
      setStatus("", "");
      lastCaptureEl.textContent = "";
    }
  }

  function setStatus(msg, type) {
    statusEl.textContent = msg;
    statusEl.className = type;
  }

  // page_purpose is server/Claude-derived — always escaped. The numeric
  // fields are coerced with Number() so nothing else reaches innerHTML raw.
  function renderLastCapture(lc) {
    const age = formatAge(lc.timestamp);
    lastCaptureEl.innerHTML = `
      <div class="last-capture">
        <div class="label">Last capture · ${age}</div>
        <div class="purpose">${escHtml(String(lc.page_purpose || "—"))}</div>
        <div class="stats">
          <span>+${Number(lc.words_added) || 0} new</span>
          <span class="updated">~${Number(lc.words_updated) || 0} updated</span>
          of ${Number(lc.total_words) || 0} extracted
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
    return str
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }
});
