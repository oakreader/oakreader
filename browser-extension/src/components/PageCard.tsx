import type { PageMeta } from "@/src/lib/types";
import { detectContentKind, contentKindToLabel } from "@/src/lib/translators";

interface PageCardProps {
  pageMeta: PageMeta;
}

function getDomain(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}

function getTypeLabel(type: string, url: string): string {
  switch (type) {
    case "pdf":
      return "PDF Document";
    case "embed": {
      const kind = detectContentKind(url);
      return contentKindToLabel(kind);
    }
    default:
      return contentKindToLabel(detectContentKind(url));
  }
}

/** Extract a readable filename from a PDF URL. */
function getPDFTitle(url: string): string {
  try {
    const pathname = new URL(url).pathname;
    const filename = decodeURIComponent(pathname.split("/").pop() || "");
    return filename.replace(/\.pdf$/i, "") || "PDF";
  } catch {
    return "PDF";
  }
}

function PDFIcon() {
  return (
    <svg
      className="size-8 shrink-0"
      viewBox="0 0 32 32"
      fill="none"
    >
      <rect x="4" y="2" width="24" height="28" rx="4" fill="#FF3B30" opacity="0.1" />
      <rect x="4" y="2" width="24" height="28" rx="4" stroke="#FF3B30" opacity="0.3" strokeWidth="1" />
      <text x="16" y="20" textAnchor="middle" fill="#FF3B30" fontSize="8" fontWeight="700" fontFamily="-apple-system, system-ui, sans-serif">PDF</text>
    </svg>
  );
}

export function PageCard({ pageMeta }: PageCardProps) {
  const domain = getDomain(pageMeta.url);
  const typeLabel = getTypeLabel(pageMeta.type, pageMeta.url);
  const isPDF = pageMeta.type === "pdf";

  // For PDFs, derive a clean title from URL if no title is available
  const displayTitle = isPDF
    ? pageMeta.title || getPDFTitle(pageMeta.url)
    : pageMeta.title || pageMeta.url;

  // Favicon: use page-provided or fallback to Google's favicon service
  const faviconSrc =
    pageMeta.favicon ||
    `https://www.google.com/s2/favicons?sz=32&domain=${encodeURIComponent(domain)}`;

  return (
    <div className="flex items-start gap-2.5 rounded-[var(--radius-outer)] bg-grouped p-3"
         style={{ boxShadow: "0 0 0 0.5px rgba(0,0,0,0.06)" }}>
      {isPDF ? (
        <PDFIcon />
      ) : (
        <img
          src={faviconSrc}
          alt=""
          className="size-8 rounded-[6px] shrink-0 bg-fill"
          onError={(e) => {
            (e.target as HTMLImageElement).style.display = "none";
          }}
        />
      )}
      <div className="min-w-0 flex-1 py-0.5">
        <p className="text-[13px] font-semibold leading-snug text-foreground line-clamp-2">
          {displayTitle}
        </p>
        <p className="mt-0.5 text-[11px] text-secondary">
          {domain} &middot; {typeLabel}
        </p>
      </div>
    </div>
  );
}
