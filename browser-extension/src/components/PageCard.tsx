import { ExternalLink } from "lucide-react";
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
    <svg className="size-6" viewBox="0 0 32 32" fill="none">
      <rect x="4" y="2" width="24" height="28" rx="4" fill="#FF3B30" opacity="0.12" />
      <rect x="4" y="2" width="24" height="28" rx="4" stroke="#FF3B30" opacity="0.35" strokeWidth="1" />
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
    <article className="oak-glass-card p-3.5">
      <div className="flex items-start gap-3">
        <div className="flex size-11 shrink-0 items-center justify-center overflow-hidden rounded-2xl bg-fill ring-1 ring-black/5">
          {isPDF ? (
            <PDFIcon />
          ) : (
            <img
              src={faviconSrc}
              alt=""
              className="size-7 rounded-lg bg-white shadow-sm"
              onError={(e) => {
                (e.target as HTMLImageElement).style.display = "none";
              }}
            />
          )}
        </div>
        <div className="min-w-0 flex-1">
          <div className="mb-1 flex items-center gap-1.5 text-[11px] text-secondary">
            <span className="oak-chip">{typeLabel}</span>
            <span className="truncate">{domain}</span>
          </div>
          <p className="text-[14px] font-semibold leading-snug text-foreground line-clamp-2 tracking-[-0.02em]">
            {displayTitle}
          </p>
          <div className="mt-2 inline-flex max-w-full items-center gap-1 rounded-full bg-fill px-2 py-1 text-[10.5px] text-secondary">
            <ExternalLink className="size-3 shrink-0" strokeWidth={2.2} />
            <span className="truncate">Ready to capture</span>
          </div>
        </div>
      </div>
    </article>
  );
}
