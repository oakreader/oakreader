const SERVER_BASE = "http://localhost:23119";
const SNAPSHOT_URL = `${SERVER_BASE}/snapshot`;
const COLLECTIONS_URL = `${SERVER_BASE}/collections`;

const TYPE_LABELS: Record<string, string> = {
  html: "\uD83C\uDF10 Web Page",
  embed: "\u25B6\uFE0F Embed",
};

interface PageData {
  type: string;
  url: string;
  title: string | null;
  [key: string]: unknown;
}

interface CollectionInfo {
  id: string;
  name: string;
  icon: string;
  parentId: string | null;
}

let pageData: PageData | null = null;

const loadingEl = document.getElementById("loading")!;
const contentEl = document.getElementById("content")!;
const titleEl = document.getElementById("pageTitle")!;
const typeEl = document.getElementById("pageType")!;
const saveBtn = document.getElementById("saveBtn") as HTMLButtonElement;
const statusEl = document.getElementById("status")!;
const collectionSelect = document.getElementById("collectionSelect") as HTMLSelectElement;

function showError(msg: string) {
  loadingEl.style.display = "none";
  contentEl.style.display = "block";
  document.querySelector(".card")!.setAttribute("style", "display:none");
  document.querySelector(".collection-picker")!.setAttribute("style", "display:none");
  saveBtn.style.display = "none";
  statusEl.textContent = msg;
  statusEl.className = "status error";
}

async function loadCollections() {
  try {
    const response = await fetch(COLLECTIONS_URL);
    const collections: CollectionInfo[] = await response.json();

    for (const coll of collections) {
      const option = document.createElement("option");
      option.value = coll.id;
      // Indent subcollections
      const prefix = coll.parentId ? "\u00A0\u00A0\u00A0\u00A0" : "";
      option.textContent = prefix + coll.name;
      collectionSelect.appendChild(option);
    }
  } catch {
    // Server not running or no collections — keep just "Inbox"
  }
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

    // Load collections in parallel with page data
    const collectionsPromise = loadCollections();

    pageData = await chrome.tabs.sendMessage(tab.id, {
      action: "getPageData",
    });

    if (!pageData) {
      showError("Could not extract page data.");
      return;
    }

    await collectionsPromise;

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

  const selectedCollectionId = collectionSelect.value || undefined;
  const selectedOption = collectionSelect.options[collectionSelect.selectedIndex];
  const collectionName = selectedOption?.value ? selectedOption.textContent?.trim() : "Inbox";

  try {
    const body = {
      ...pageData,
      collectionId: selectedCollectionId,
    };

    const response = await fetch(SNAPSHOT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

    const result = await response.json();

    if (result.status === "ok") {
      statusEl.textContent = `Saved to ${collectionName}.`;
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
