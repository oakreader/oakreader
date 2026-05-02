import type { PageMeta } from "@/src/lib/types";

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

function getTypeLabel(type: string): string {
  switch (type) {
    case "embed":
      return "Video";
    case "pdf":
      return "PDF Document";
    default:
      return "Web Page";
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
      className="size-5 mt-0.5 shrink-0 text-red-500"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z" />
      <path d="M14 2v4a2 2 0 0 0 2 2h4" />
      <path d="M10 17v-1a1 1 0 0 1 1-1h.6a1 1 0 0 0 .9-.6l.2-.3a1 1 0 0 1 .9-.6H14" />
    </svg>
  );
}

export function PageCard({ pageMeta }: PageCardProps) {
  const domain = getDomain(pageMeta.url);
  const typeLabel = getTypeLabel(pageMeta.type);
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
    <div className="flex items-start gap-3">
      {isPDF ? (
        <PDFIcon />
      ) : (
        <img
          src={faviconSrc}
          alt=""
          className="size-5 mt-0.5 rounded shrink-0"
          onError={(e) => {
            (e.target as HTMLImageElement).style.display = "none";
          }}
        />
      )}
      <div className="min-w-0 flex-1">
        <p className="text-[13px] font-medium leading-snug text-foreground line-clamp-2">
          {displayTitle}
        </p>
        <p className="mt-0.5 text-[11px] text-muted-foreground truncate">
          {domain} &middot; {typeLabel}
        </p>
      </div>
    </div>
  );
}
