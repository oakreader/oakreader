import type { MetadataRoute } from "next";
import { LOCALES, LOCALE_META } from "@/i18n/config";

const SITE_URL = "https://oakreader.com";

function urlFor(path: string): string {
  return path ? `${SITE_URL}${path}` : `${SITE_URL}/`;
}

// One entry per locale, each carrying the full hreflang alternate set so search
// engines understand they're translations of the same page (x-default → `/`).
export default function sitemap(): MetadataRoute.Sitemap {
  const languages: Record<string, string> = {};
  for (const l of LOCALES) {
    languages[LOCALE_META[l].hreflang] = urlFor(LOCALE_META[l].path);
  }

  return LOCALES.map((l) => ({
    url: urlFor(LOCALE_META[l].path),
    lastModified: "2026-06-19",
    changeFrequency: "monthly",
    priority: l === "en" ? 1 : 0.8,
    alternates: { languages },
  }));
}
