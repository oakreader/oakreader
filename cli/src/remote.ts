/**
 * Fetching a document that lives on the web.
 *
 * Separate from `import.ts` because it is about HTTP rather than the library:
 * what a URL actually serves, and what a page says about itself. The Swift app
 * has the same three functions (`ImportService+URL.swift`), and the answers
 * here have to match — a PDF the app would recognise cannot be a bookmark when
 * the terminal fetches it.
 */

/**
 * A desktop user agent.
 *
 * Not politeness: several publishers (arXiv among them) serve a challenge page
 * to an unrecognised client, so a default `bun/1.x` agent downloads HTML with
 * a .pdf in its name.
 */
const BROWSER_USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
  + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36";

export interface RemoteInfo {
  contentType: string | null;
  html: string | null;
  title: string | null;
  author: string | null;
  description: string | null;
  thumbnailURL: string | null;
}

/** The content type a URL serves, by asking for the headers alone. */
async function probeContentType(url: string): Promise<string | null> {
  try {
    const response = await fetch(url, {
      method: "HEAD",
      headers: { "User-Agent": BROWSER_USER_AGENT },
      signal: AbortSignal.timeout(12_000),
    });
    return response.headers.get("content-type");
  } catch {
    return null;
  }
}

/**
 * Whether a URL serves a PDF.
 *
 * The extension is a hint, not the answer: `arxiv.org/pdf/2406.08929` has no
 * extension at all and is a PDF, while plenty of `.pdf?download=1` links are
 * redirects to HTML. Asking the server settles it.
 */
export function isLikelyPDF(url: string, contentType: string | null): boolean {
  try {
    const path = new URL(url).pathname.toLowerCase();
    if (path.endsWith(".pdf")) return true;
  } catch { /* a malformed URL is not a PDF */ }
  return contentType?.toLowerCase().includes("application/pdf") ?? false;
}

/** The first match of a meta tag's content attribute, in either attribute order. */
function meta(html: string, kind: "property" | "name", key: string): string | null {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  for (const pattern of [
    new RegExp(`<meta[^>]+${kind}=["']${escaped}["'][^>]+content=["']([^"']*)["']`, "i"),
    new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]+${kind}=["']${escaped}["']`, "i"),
  ]) {
    const found = pattern.exec(html)?.[1]?.trim();
    if (found !== undefined && found !== "") return found;
  }
  return null;
}

function documentTitle(html: string): string | null {
  const found = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1]?.trim();
  return found !== undefined && found !== "" ? found : null;
}

function absolute(candidate: string | null, base: string): string | null {
  if (candidate === null) return null;
  try {
    return new URL(candidate, base).toString();
  } catch {
    return null;
  }
}

/**
 * What a URL serves and what it says about itself.
 *
 * A PDF is not downloaded here — only its content type is needed, and the body
 * may be tens of megabytes. For anything else the body is fetched once and
 * reused: the caller needs it for the title, the description and the readable
 * text, and fetching three times to get them would be absurd.
 */
export async function remoteInfo(url: string): Promise<RemoteInfo> {
  const headType = await probeContentType(url);
  const empty: RemoteInfo = {
    contentType: headType, html: null, title: null,
    author: null, description: null, thumbnailURL: null,
  };
  if (isLikelyPDF(url, headType)) return empty;

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { "User-Agent": BROWSER_USER_AGENT },
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    return empty;
  }
  const contentType = response.headers.get("content-type") ?? headType;
  // A server that only reveals the type on GET (no HEAD support) can still
  // turn out to be serving a PDF, and downloading it as a "web page" would
  // file a binary as an article.
  if (isLikelyPDF(url, contentType)) return { ...empty, contentType };

  let html: string;
  try {
    html = await response.text();
  } catch {
    return { ...empty, contentType };
  }

  return {
    contentType,
    html,
    title: documentTitle(html)
      ?? meta(html, "property", "og:title")
      ?? meta(html, "name", "twitter:title"),
    author: meta(html, "name", "author") ?? meta(html, "property", "article:author"),
    description: meta(html, "property", "og:description")
      ?? meta(html, "name", "description")
      ?? meta(html, "name", "twitter:description"),
    thumbnailURL: absolute(
      meta(html, "property", "og:image") ?? meta(html, "name", "twitter:image"), url),
  };
}

/**
 * Download a URL to a file, refusing anything that is not really a PDF.
 *
 * The magic number rather than the content type: a login wall and a rate-limit
 * page are both served as HTML with a 200, and filing one as a paper is worse
 * than failing.
 */
export async function downloadPDF(url: string, path: string): Promise<void> {
  const response = await fetch(url, {
    headers: { "User-Agent": BROWSER_USER_AGENT },
    redirect: "follow",
    signal: AbortSignal.timeout(120_000),
  });
  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText}`);
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  const magic = new TextDecoder().decode(bytes.slice(0, 4));
  if (magic !== "%PDF") {
    throw new Error("the download is not a PDF (the link may need a login)");
  }
  await Bun.write(path, bytes);
}

/** A filename for a downloaded PDF, from the URL or the title. */
export function pdfFileName(url: string, title: string | null): string {
  let candidate = "";
  try {
    candidate = decodeURIComponent(new URL(url).pathname.split("/").filter(Boolean).pop() ?? "");
  } catch { /* fall through to the title */ }
  if (!candidate.toLowerCase().endsWith(".pdf")) {
    const base = (candidate !== "" ? candidate : title ?? "download").slice(0, 120);
    candidate = `${base}.pdf`;
  }
  return candidate.replace(/[/\\:*?"<>|]/g, "-").replace(/^\.+/, "");
}
