const SERVER_URL = "http://localhost:23119/snapshot";

const TYPE_LABELS: Record<string, string> = {
  html: "\uD83C\uDF10 Web Page",
  youtube: "\u25B6\uFE0F YouTube Video",
  podcast: "\uD83C\uDFA7 Podcast",
};

interface PageData {
  type: string;
  url: string;
  title: string | null;
  [key: string]: unknown;
}

let pageData: PageData | null = null;

const loadingEl = document.getElementById("loading")!;
const contentEl = document.getElementById("content")!;
const titleEl = document.getElementById("pageTitle")!;
const typeEl = document.getElementById("pageType")!;
const saveBtn = document.getElementById("saveBtn") as HTMLButtonElement;
const statusEl = document.getElementById("status")!;

function showError(msg: string) {
  loadingEl.style.display = "none";
  contentEl.style.display = "block";
  document.querySelector(".card")!.setAttribute("style", "display:none");
  saveBtn.style.display = "none";
  statusEl.textContent = msg;
  statusEl.className = "status error";
}

async function init() {
  try {
    const [tab] = await chrome.tabs.query({
      active: true,
      currentWindow: true,
    });

    if (!tab?.id) {
      showError("Cannot access this page.");
      return;
    }

    pageData = await chrome.tabs.sendMessage(tab.id, {
      action: "getPageData",
    });

    if (!pageData) {
      showError("Could not extract page data.");
      return;
    }

    loadingEl.style.display = "none";
    contentEl.style.display = "block";
    titleEl.textContent = pageData.title || tab.url || "";
    typeEl.textContent = TYPE_LABELS[pageData.type] || "\uD83C\uDF10 Web Page";
  } catch {
    showError("Cannot access this page. Try a regular web page.");
  }
}

saveBtn.addEventListener("click", async () => {
  if (!pageData) return;

  saveBtn.disabled = true;
  saveBtn.textContent = "Saving...";
  statusEl.textContent = "";
  statusEl.className = "status";

  try {
    const response = await fetch(SERVER_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(pageData),
    });

    const result = await response.json();

    if (result.status === "ok") {
      statusEl.textContent = "Saved! Added to Inbox.";
      statusEl.className = "status success";
      saveBtn.textContent = "Saved";
    } else {
      statusEl.textContent = result.message || "Unknown error";
      statusEl.className = "status error";
      saveBtn.disabled = false;
      saveBtn.textContent = "Save to OakReader";
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("Failed to fetch") || msg.includes("NetworkError")) {
      statusEl.textContent = "OakReader is not running.";
    } else {
      statusEl.textContent = msg;
    }
    statusEl.className = "status error";
    saveBtn.disabled = false;
    saveBtn.textContent = "Save to OakReader";
  }
});

init();
