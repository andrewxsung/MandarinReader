document.addEventListener("DOMContentLoaded", async () => {
  const settings = await chrome.storage.sync.get({
    claudeApiKey: "",
    backendUrl: "http://localhost:8000",
    mrApiKey: "",
  });

  document.getElementById("apiKey").value = settings.claudeApiKey;
  document.getElementById("backendUrl").value = settings.backendUrl;
  document.getElementById("mrApiKey").value = settings.mrApiKey;

  document.getElementById("saveBtn").addEventListener("click", async () => {
    const apiKey = document.getElementById("apiKey").value.trim();
    const backendUrl = document.getElementById("backendUrl").value.trim().replace(/\/$/, "");
    const mrApiKey = document.getElementById("mrApiKey").value.trim();

    await chrome.storage.sync.set({ claudeApiKey: apiKey, backendUrl, mrApiKey });

    const saved = document.getElementById("saved");
    saved.style.display = "inline";
    setTimeout(() => (saved.style.display = "none"), 2500);
  });
});
