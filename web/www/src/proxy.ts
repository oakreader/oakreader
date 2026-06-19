// Next.js 16 renamed `middleware` → `proxy` (file + exported function). This runs
// before every page request to pick a locale:
//   • non-default locale already in the path (/ja, /zh, …) → pass through
//   • /en or /en/... → redirect to the de-prefixed canonical URL (default at /)
//   • no locale in the path → detect from cookie / Accept-Language, then
//       - default locale  → rewrite to /en internally (URL stays at /)
//       - other locale     → redirect to /<locale>
import { NextResponse, type NextRequest } from "next/server";
import { match } from "@formatjs/intl-localematcher";
import Negotiator from "negotiator";
import {
  LOCALES,
  DEFAULT_LOCALE,
  COOKIE_NAME,
  isLocale,
} from "@/i18n/config";

const PREFIXED: string[] = LOCALES.filter((l) => l !== DEFAULT_LOCALE);
const ONE_YEAR = 60 * 60 * 24 * 365;

function detectLocale(request: NextRequest): string {
  const cookie = request.cookies.get(COOKIE_NAME)?.value;
  if (cookie && isLocale(cookie)) return cookie;

  const acceptLanguage = request.headers.get("accept-language") ?? "";
  const languages = new Negotiator({
    headers: { "accept-language": acceptLanguage },
  }).languages();

  try {
    return match(languages, LOCALES as readonly string[], DEFAULT_LOCALE);
  } catch {
    return DEFAULT_LOCALE;
  }
}

function rememberLocale(response: NextResponse, locale: string): NextResponse {
  response.cookies.set(COOKIE_NAME, locale, {
    path: "/",
    maxAge: ONE_YEAR,
    sameSite: "lax",
  });
  return response;
}

export function proxy(request: NextRequest): NextResponse {
  const { pathname } = request.nextUrl;
  const segment = pathname.split("/")[1];

  // Already on a non-default prefixed locale — serve it, refresh the cookie.
  if (PREFIXED.includes(segment)) {
    return rememberLocale(NextResponse.next(), segment);
  }

  // /en or /en/... — the default locale is canonical at `/`, so strip the prefix.
  if (segment === DEFAULT_LOCALE) {
    const url = request.nextUrl.clone();
    url.pathname = pathname.replace(/^\/en(?=\/|$)/, "") || "/";
    return rememberLocale(NextResponse.redirect(url), DEFAULT_LOCALE);
  }

  // No locale in the path — negotiate one.
  const locale = detectLocale(request);
  const rest = pathname === "/" ? "" : pathname;
  const url = request.nextUrl.clone();

  if (locale === DEFAULT_LOCALE) {
    // Serve English at the bare URL via an internal rewrite (URL unchanged).
    url.pathname = `/${DEFAULT_LOCALE}${rest}`;
    return rememberLocale(NextResponse.rewrite(url), DEFAULT_LOCALE);
  }

  url.pathname = `/${locale}${rest}`;
  return rememberLocale(NextResponse.redirect(url), locale);
}

export const config = {
  // Run on everything except Next internals, API routes, and static files
  // (anything with a dot, e.g. /icon.svg, /favicon.ico, /shots/x.png).
  matcher: ["/((?!_next|api|.*\\.).*)"],
};
