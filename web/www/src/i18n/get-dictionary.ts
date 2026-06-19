import "server-only";
import type { Locale } from "./config";
import type en from "./dictionaries/en.json";

// All UI copy lives in per-locale JSON dictionaries, loaded on the server only —
// so the (combined) translations never ship to the client bundle.
const dictionaries = {
  en: () => import("./dictionaries/en.json").then((m) => m.default),
  zh: () => import("./dictionaries/zh.json").then((m) => m.default),
  ja: () => import("./dictionaries/ja.json").then((m) => m.default),
  ko: () => import("./dictionaries/ko.json").then((m) => m.default),
  de: () => import("./dictionaries/de.json").then((m) => m.default),
  fr: () => import("./dictionaries/fr.json").then((m) => m.default),
  es: () => import("./dictionaries/es.json").then((m) => m.default),
} satisfies Record<Locale, () => Promise<unknown>>;

// `en.json` is the source of truth for the dictionary shape; every other locale
// must match it.
export type Dictionary = typeof en;

export const getDictionary = (locale: Locale): Promise<Dictionary> =>
  dictionaries[locale]() as Promise<Dictionary>;
