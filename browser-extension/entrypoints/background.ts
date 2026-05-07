export default defineBackground(() => {
  const SNAPSHOT_URL = "http://127.0.0.1:23119/snapshot";

  // ─── PDF Detection via webRequest ──────────────────────────────────────────────

  const pdfTabs = new Map<number, { url: string }>();

  chrome.webRequest.onHeadersReceived.addListener(
    (details) => {
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

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
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
  });

  // ─── Full-Page PDF via Debugger (Page.printToPDF) → POST to server ─────────────

  // A4 dimensions in inches
  const A4_WIDTH = 8.27;
  const A4_HEIGHT = 11.69;

  async function captureAndSavePDF(
    tabId: number,
    payload: {
      url: string;
      title: string | null;
      collectionId?: string;
      tagOptionIds?: string[];
      newTags?: string[];
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

      // Measure full page height so we can render it as one long PDF page
      const heightResult = (await chrome.debugger.sendCommand(
        target,
        "Runtime.evaluate",
        { expression: "document.documentElement.scrollHeight", returnByValue: true }
      )) as { result: { value: number } };
      const pageHeightInches = heightResult.result.value / 96;

      const printResult = (await chrome.debugger.sendCommand(
        target,
        "Page.printToPDF",
        {
          printBackground: true,
          displayHeaderFooter: false,
          paperWidth: A4_WIDTH,
          paperHeight: pageHeightInches,
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
    const body: Record<string, unknown> = {
      type: "pdf",
      url: payload.url,
      title: payload.title,
      pdfData: pdfBase64,
      markdown,
    };
    if (payload.collectionId) body.collectionId = payload.collectionId;
    if (payload.tagOptionIds && payload.tagOptionIds.length > 0) body.tagOptionIds = payload.tagOptionIds;
    if (payload.newTags && payload.newTags.length > 0) body.newTags = payload.newTags;

    const response = await fetch(SNAPSHOT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

    return response.json();
  }
});
