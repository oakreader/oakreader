import type { HTMLSnapshotPayload, PDFCapturePayload } from "@/src/lib/types";

export default defineBackground(() => {
  const CLIP_URL = "http://127.0.0.1:23119/clip";

  // ─── PDF Detection via webRequest ──────────────────────────────────────────────

  const pdfTabs = new Map<number, { url: string }>();

  chrome.webRequest.onHeadersReceived.addListener(
    (details): chrome.webRequest.BlockingResponse | undefined => {
      if (details.type !== "main_frame") return;
      const ct = details.responseHeaders?.find(
        (h) => h.name.toLowerCase() === "content-type"
      );
      if (ct?.value?.includes("application/pdf")) {
        pdfTabs.set(details.tabId, { url: details.url });
      } else {
        pdfTabs.delete(details.tabId);
      }
    },
    { urls: ["<all_urls>"] },
    ["responseHeaders"]
  );

  // Clean up when tabs are closed
  chrome.tabs.onRemoved.addListener((tabId) => {
    pdfTabs.delete(tabId);
  });

  // ─── Message Handlers ─────────────────────────────────────────────────────────

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.method === "isPDFTab") {
      const info = pdfTabs.get(message.tabId);
      sendResponse(info ? { isPDF: true, url: info.url } : { isPDF: false });
      return true;
    }

    if (message.method === "getCookiesForURL") {
      chrome.cookies.getAll({ url: message.url }).then((cookies) => {
        const cookieStr = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
        sendResponse({ cookies: cookieStr });
      });
      return true;
    }

    if (message.method === "captureAndSavePDF") {
      captureAndSavePDF(message.tabId, message.payload)
        .then(sendResponse)
        .catch((error) =>
          sendResponse({ status: "error", message: error instanceof Error ? error.message : String(error) })
        );
      return true;
    }

    if (message.method === "captureAndSaveHTML") {
      captureAndSaveHTML(message.tabId, message.payload)
        .then(sendResponse)
        .catch((error) =>
          sendResponse({ status: "error", message: error instanceof Error ? error.message : String(error) })
        );
      return true;
    }

    // ─── SingleFile fetch proxy ─────────────────────────────────────────────────
    // Content script proxies cross-origin resource fetches through the background
    // service worker, which has broader network access via host_permissions.

    if (message.method === "singlefile.fetch") {
      handleSingleFileFetch(message, sender.tab?.id)
        .then(sendResponse)
        .catch((error) =>
          sendResponse({ error: error instanceof Error ? error.message : String(error) })
        );
      return true;
    }

    // Fetch an og:image (or any cover) through the SW, which has cross-origin host
    // permissions, and return it as base64 so the app stores it directly as a cover.
    if (message.method === "fetchThumbnail") {
      handleFetchThumbnail(message)
        .then(sendResponse)
        .catch((error) =>
          sendResponse({ error: error instanceof Error ? error.message : String(error) })
        );
      return true;
    }

    // Progress events from content script → popup receives directly via onMessage
    if (message.method === "singlefile.progress") {
      return false;
    }
  });

  // ─── SingleFile Fetch Proxy ───────────────────────────────────────────────────

  async function handleSingleFileFetch(
    message: { url: string; referrer?: string; headers?: Record<string, string> },
    _tabId?: number
  ) {
    const response = await fetch(message.url, {
      headers: message.headers,
      referrer: message.referrer,
    });
    const arrayBuffer = await response.arrayBuffer();
    const headers: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      headers[key] = value;
    });
    return {
      status: response.status,
      headers,
      array: Array.from(new Uint8Array(arrayBuffer)),
    };
  }

  // ─── Thumbnail (og:image) Fetch → base64 ──────────────────────────────────────

  async function handleFetchThumbnail(
    message: { url: string; referrer?: string }
  ): Promise<{ base64?: string; contentType?: string; error?: string }> {
    // Referer = the page being clipped, so hotlink-protected CDNs (bilibili, weibo) serve it.
    const response = await fetch(message.url, { referrer: message.referrer });
    if (!response.ok) return { error: `HTTP ${response.status}` };

    const contentType = response.headers.get("content-type") ?? "";
    if (!contentType.startsWith("image/")) return { error: `not an image: ${contentType}` };

    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength === 0) return { error: "empty image" };
    if (bytes.byteLength > 5_000_000) return { error: "image too large" };

    // Chunked btoa — String.fromCharCode.apply on the whole array overflows the call stack.
    let binary = "";
    const CHUNK = 0x8000;
    for (let i = 0; i < bytes.length; i += CHUNK) {
      binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
    }
    return { base64: btoa(binary), contentType };
  }

  // ─── SingleFile Script Injection ──────────────────────────────────────────────

  async function injectSingleFileScripts(tabId: number): Promise<void> {
    // 1. Hooks → all frames, MAIN world (intercepts lazy-load: IntersectionObserver, etc.)
    //    Must run BEFORE page resources are loaded, so inject first.
    await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      files: ["lib/single-file-hooks-frames.js"],
      ...({ world: "MAIN" } as any),
    });
    // 2. Main engine → main frame, ISOLATED world
    //    This is the only script needed for getPageData(). It's self-contained (834KB).
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["lib/single-file.js"],
    });
  }

  function getSingleFileOptions() {
    return {
      removeHiddenElements: true,
      removeUnusedStyles: true,
      removeUnusedFonts: true,
      removeFrames: true,
      compressHTML: true,
      loadDeferredImages: false,
      filenameTemplate: "{page-title}",
      infobarContent: "",
      includeInfobar: false,
      insertMetaCSP: true,
      blockScripts: true,
      blockVideos: false,
      blockAudios: false,
    };
  }

  // ─── HTML Snapshot via SingleFile → POST to server ────────────────────────────

  async function captureAndSaveHTML(
    tabId: number,
    payload: {
      url: string;
      title: string | null;
    }
  ): Promise<{ status: string; message?: string }> {
    // 0. Extract markdown (best-effort)
    let markdown: string | null = null;
    try {
      const resp = await chrome.tabs.sendMessage(tabId, { action: "extractMarkdown" });
      if (resp?.markdown) markdown = resp.markdown;
    } catch {
      // Markdown extraction is best-effort
    }

    // 0b. Read the live-page preview image (og:image) from the rendered DOM, so the app uses the
    //     browser's thumbnail directly instead of a server-side re-fetch the site may block
    //     (X, Instagram, Dribbble, 知乎, 小红书, 微博…). Best-effort.
    let thumbnailURL: string | null = null;
    try {
      const meta = await chrome.tabs.sendMessage(tabId, { action: "extractMeta" });
      if (meta?.thumbnailURL) thumbnailURL = meta.thumbnailURL;
    } catch {
      // Thumbnail extraction is best-effort
    }

    // 1. Inject SingleFile scripts into the page
    try {
      await injectSingleFileScripts(tabId);
    } catch (err) {
      return {
        status: "error",
        message: `Script injection failed: ${err instanceof Error ? err.message : String(err)}`,
      };
    }

    // 2. Request HTML capture from content script
    let html: string;
    try {
      const result = await chrome.tabs.sendMessage(tabId, {
        action: "captureHTML",
        options: getSingleFileOptions(),
      });
      if (result === undefined) {
        return { status: "error", message: "Content script did not respond. Please refresh the page and try again." };
      }
      if (!result?.html) {
        return { status: "error", message: result?.error || "HTML capture returned empty content" };
      }
      html = result.html;
    } catch (err) {
      return {
        status: "error",
        message: `HTML capture failed: ${err instanceof Error ? err.message : String(err)}`,
      };
    }

    // 3. POST to OakReader server
    const body: HTMLSnapshotPayload = {
      type: "html",
      url: payload.url,
      title: payload.title,
      html,
      markdown,
      thumbnailURL,
    };

    const response = await fetch(CLIP_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

    return response.json();
  }

  // ─── Full-Page PDF via Debugger (Page.printToPDF) → POST to server ─────────────

  // A4 dimensions in inches
  const A4_WIDTH = 8.27;
  const A4_HEIGHT = 11.69;

  async function captureAndSavePDF(
    tabId: number,
    payload: {
      url: string;
      title: string | null;
    }
  ): Promise<{ status: string; message?: string }> {
    // 0. Extract markdown from the page before attaching debugger
    let markdown: string | null = null;
    try {
      const resp = await chrome.tabs.sendMessage(tabId, { action: "extractMarkdown" });
      if (resp?.markdown) markdown = resp.markdown;
    } catch {
      // Markdown extraction is best-effort; don't block PDF capture
    }

    // 1. Generate PDF via debugger
    const target = { tabId };
    let pdfBase64: string;

    // Verify the tab is a regular web page (debugger can't attach to extension/chrome pages)
    try {
      const tab = await chrome.tabs.get(tabId);
      if (!tab.url || !tab.url.startsWith("http")) {
        return { status: "error", message: `Cannot generate PDF for this page (${tab.url?.split(":")[0] ?? "unknown"} URL)` };
      }
    } catch {
      return { status: "error", message: "Tab not found" };
    }

    try {
      await chrome.debugger.attach(target, "1.3");
    } catch (err) {
      return { status: "error", message: `Debugger attach failed: ${err instanceof Error ? err.message : String(err)}` };
    }

    try {
      // Set emulated media to "screen" so print-specific CSS doesn't alter layout
      await chrome.debugger.sendCommand(target, "Emulation.setEmulatedMedia", {
        media: "screen",
      });

      // Set viewport width to match A4 paper width in pixels
      const contentWidthPx = Math.round(A4_WIDTH * 96);
      await chrome.debugger.sendCommand(target, "Emulation.setDeviceMetricsOverride", {
        width: contentWidthPx,
        height: 0,
        deviceScaleFactor: 1,
        scale: 1,
        mobile: false,
      });

      // Wait for layout to settle after viewport change
      await new Promise((r) => setTimeout(r, 500));

      const printResult = (await chrome.debugger.sendCommand(
        target,
        "Page.printToPDF",
        {
          printBackground: true,
          displayHeaderFooter: false,
          paperWidth: A4_WIDTH,
          paperHeight: A4_HEIGHT,
          marginTop: 0,
          marginRight: 0,
          marginBottom: 0,
          marginLeft: 0,
          scale: 1,
        }
      )) as { data: string };

      await chrome.debugger.sendCommand(target, "Emulation.clearDeviceMetricsOverride");

      if (!printResult?.data) {
        return { status: "error", message: "printToPDF returned empty data" };
      }

      pdfBase64 = printResult.data;
    } catch (err) {
      return { status: "error", message: err instanceof Error ? err.message : String(err) };
    } finally {
      try {
        await chrome.debugger.detach(target);
      } catch {
        // Already detached or tab closed
      }
    }

    // 2. POST directly to the OakReader server from background
    const body: PDFCapturePayload = {
      type: "pdf",
      url: payload.url,
      title: payload.title,
      pdfData: pdfBase64,
      markdown,
    };

    const response = await fetch(CLIP_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

    return response.json();
  }
});
