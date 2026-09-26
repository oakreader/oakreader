// i18n configuration — shared by Server Components, the language switcher, and
// the locale-detection proxy (src/proxy.ts). Keep this file free of `server-only`
// so client components (the switcher) can import the metadata too.

export const DEFAULT_LOCALE = "en";

// Route segment values. `en` is the default and is served at `/` (no prefix);
// every other locale lives under its own sub-path (`/zh`).
export const LOCALES = ["en", "zh"] as const;

export type Locale = (typeof LOCALES)[number];

// Cookie that remembers a visitor's chosen/detected locale so the proxy only
// negotiates once.
export const COOKIE_NAME = "OAK_LOCALE";

type LocaleInfo = {
  /** hreflang value emitted in <link rel="alternate"> + sitemap. */
  hreflang: string;
  /** value for the <html lang> attribute. */
  htmlLang: string;
  /** native name shown in the language switcher. */
  name: string;
  /** URL path prefix; empty string for the default locale (served at `/`). */
  path: string;
};

export const LOCALE_META: Record<Locale, LocaleInfo> = {
  en: { hreflang: "en", htmlLang: "en", name: "English", path: "" },
  zh: { hreflang: "zh-Hans", htmlLang: "zh-Hans", name: "简体中文", path: "/zh" },
};

/** Type guard that narrows an arbitrary string (e.g. a route param) to a Locale. */
export function isLocale(value: string): value is Locale {
  return (LOCALES as readonly string[]).includes(value);
}

/** Home path for a locale: `/` for the default, `/<seg>` otherwise. */
export function localeHome(locale: Locale): string {
  return LOCALE_META[locale].path || "/";
}
