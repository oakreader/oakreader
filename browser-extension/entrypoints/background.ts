export default defineBackground(() => {
  const MAX_CONTENT_SIZE = 8 * (1024 * 1024);

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

    if (message.method === "singlefile.fetch") {
      handleSingleFileFetch(message, sender)
        .then(sendResponse)
        .catch((error) =>
          sendResponse({ error: error?.message || String(error) })
        );
      return true;
    }

    if (message.method === "singlefile.fetchFrame") {
      chrome.tabs.sendMessage(sender.tab!.id!, message).then(sendResponse);
      return true;
    }
  });

  async function handleSingleFileFetch(
    message: {
      url: string;
      requestId: number;
      referrer?: string;
      headers?: Record<string, string>;
    },
    sender: chrome.runtime.MessageSender
  ) {
    try {
      const response = await fetchResource(message.url, {
        referrer: message.referrer,
        headers: message.headers,
      });
      return sendChunkedResponse(
        sender.tab!.id!,
        message.requestId,
        response
      );
    } catch (error: unknown) {
      return sendChunkedResponse(sender.tab!.id!, message.requestId, {
        error: error instanceof Error ? error.message : String(error),
        array: [],
        headers: {},
        status: 0,
      });
    }
  }

  async function fetchResource(
    url: string,
    options: { referrer?: string; headers?: Record<string, string> }
  ) {
    const fetchOptions: RequestInit = {
      cache: "no-store",
      credentials: "omit",
    };

    if (options.referrer) {
      fetchOptions.referrer = options.referrer;
      fetchOptions.referrerPolicy = "unsafe-url";
    }

    if (options.headers) {
      fetchOptions.headers = options.headers;
    }

    const response = await fetch(url, fetchOptions);
    const array = Array.from(new Uint8Array(await response.arrayBuffer()));
    const headers: Record<string, string> = {
      "content-type": response.headers.get("content-type") || "",
    };
    return {
      array,
      headers,
      status: response.status,
    };
  }

  async function sendChunkedResponse(
    tabId: number,
    requestId: number,
    response: {
      array: number[];
      headers: Record<string, string>;
      status: number;
      error?: string;
    }
  ) {
    for (
      let blockIndex = 0;
      blockIndex * MAX_CONTENT_SIZE <= response.array.length;
      blockIndex++
    ) {
      const message: Record<string, unknown> = {
        method: "singlefile.fetchResponse",
        requestId,
        headers: response.headers,
        status: response.status,
        error: response.error,
      };
      message.truncated = response.array.length > MAX_CONTENT_SIZE;
      if (message.truncated) {
        message.finished =
          (blockIndex + 1) * MAX_CONTENT_SIZE > response.array.length;
        message.array = response.array.slice(
          blockIndex * MAX_CONTENT_SIZE,
          (blockIndex + 1) * MAX_CONTENT_SIZE
        );
      } else {
        message.array = response.array;
      }
      await chrome.tabs.sendMessage(tabId, message);
    }
    return {};
  }
});
