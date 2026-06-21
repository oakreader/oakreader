import type { Metadata } from "next";
import { Inter, Space_Mono } from "next/font/google";
import localFont from "next/font/local";
import { notFound } from "next/navigation";
import "../globals.css";
import {
  LOCALES,
  LOCALE_META,
  isLocale,
  type Locale,
} from "@/i18n/config";
import { getDictionary } from "@/i18n/get-dictionary";

// Canonical origin — used for metadataBase, hreflang alternates, and the sitemap.
const SITE_URL = "https://oakreader.com";

// Inter — clean, modern grotesque sans-serif matching fabric.so's body font
const inter = Inter({
  variable: "--font-geist-sans",
  subsets: ["latin"],
  weight: ["300", "400", "500", "600", "700"],
  style: ["normal", "italic"],
});

// Exposure VAR — variable display font extracted from Dia
const exposure = localFont({
  variable: "--font-exposure",
  src: [
    { path: "../../../public/fonts/exposure-1.woff2", weight: "1", style: "normal" },
    { path: "../../../public/fonts/exposure-50.woff2", weight: "50", style: "normal" },
    { path: "../../../public/fonts/exposure-100.woff2", weight: "100", style: "normal" },
    { path: "../../../public/fonts/exposure-150.woff2", weight: "150", style: "normal" },
    { path: "../../../public/fonts/exposure-200.woff2", weight: "200", style: "normal" },
    { path: "../../../public/fonts/exposure-250.woff2", weight: "250", style: "normal" },
    { path: "../../../public/fonts/exposure-300.woff2", weight: "300", style: "normal" },
    { path: "../../../public/fonts/exposure-350.woff2", weight: "350", style: "normal" },
    { path: "../../../public/fonts/exposure-400.woff2", weight: "400", style: "normal" },
    { path: "../../../public/fonts/exposure-450.woff2", weight: "450", style: "normal" },
    { path: "../../../public/fonts/exposure-500.woff2", weight: "500", style: "normal" },
    { path: "../../../public/fonts/exposure-550.woff2", weight: "550", style: "normal" },
    { path: "../../../public/fonts/exposure-550-italic.woff2", weight: "550", style: "italic" },
    { path: "../../../public/fonts/exposure-600.woff2", weight: "600", style: "normal" },
    { path: "../../../public/fonts/exposure-650.woff2", weight: "650", style: "normal" },
    { path: "../../../public/fonts/exposure-700.woff2", weight: "700", style: "normal" },
    { path: "../../../public/fonts/exposure-750.woff2", weight: "750", style: "normal" },
    { path: "../../../public/fonts/exposure-800.woff2", weight: "800", style: "normal" },
    { path: "../../../public/fonts/exposure-850.woff2", weight: "850", style: "normal" },
    { path: "../../../public/fonts/exposure-900.woff2", weight: "900", style: "normal" },
  ],
});

// ABC Favorit Mono alternative — design-oriented monospace
const spaceMono = Space_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
  weight: ["400", "700"],
  style: ["normal", "italic"],
});

export function generateStaticParams() {
  return LOCALES.map((lang) => ({ lang }));
}

const KEYWORDS =
  "context library, AI research agent, reading app, macOS, PDF reader, knowledge base, AI research, full-text search";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ lang: string }>;
}): Promise<Metadata> {
  const { lang } = await params;
  if (!isLocale(lang)) return {};

  const dict = await getDictionary(lang);
  const canonical = LOCALE_META[lang].path || "/";

  // hreflang map: every locale points at its own path; x-default → `/` (English).
  const languages: Record<string, string> = {};
  for (const l of LOCALES) {
    languages[LOCALE_META[l].hreflang] = LOCALE_META[l].path || "/";
  }
  languages["x-default"] = "/";

  return {
    metadataBase: new URL(SITE_URL),
    title: dict.meta.title,
    description: dict.meta.description,
    keywords: KEYWORDS,
    alternates: { canonical, languages },
    openGraph: {
      type: "website",
      siteName: "Oak",
      locale: LOCALE_META[lang].hreflang,
      url: canonical,
      title: dict.meta.title,
      description: dict.meta.description,
    },
    twitter: {
      card: "summary_large_image",
      title: dict.meta.title,
      description: dict.meta.description,
    },
  };
}

export default async function RootLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  if (!isLocale(lang)) notFound();

  return (
    <html
      lang={LOCALE_META[lang as Locale].htmlLang}
      className={`${inter.variable} ${spaceMono.variable} ${exposure.variable} antialiased`}
    >
      <body className="min-h-dvh overflow-x-hidden font-sans">{children}</body>
    </html>
  );
}
