"use client";

import { useEffect, useRef, useState } from "react";
import { LOCALES, LOCALE_META, type Locale } from "@/i18n/config";

// Globe-icon dropdown. Each entry links to `/<locale>` (always prefixed, even
// English → `/en`) so the proxy refreshes the OAK_LOCALE cookie and then serves
// the canonical URL — otherwise a stale cookie would override the new choice.
export function LocaleSwitcher({
  current,
  label,
}: {
  current: Locale;
  label: string;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", onClick);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onClick);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={label}
        className="flex items-center gap-[0.5rem] h-[3.8rem] px-[1.2rem] rounded-[1.2rem] text-callout font-medium text-black/70 hover:bg-black/5 transition-colors cursor-pointer whitespace-nowrap"
      >
        <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true">
          <circle cx="12" cy="12" r="9.5" />
          <path d="M2.5 12h19M12 2.5c2.6 2.6 4 6 4 9.5s-1.4 6.9-4 9.5c-2.6-2.6-4-6-4-9.5s1.4-6.9 4-9.5Z" />
        </svg>
        <span className="hidden lg:inline">{LOCALE_META[current].name}</span>
      </button>

      {open && (
        <div
          role="menu"
          className="absolute right-0 top-full mt-[0.8rem] min-w-[15rem] rounded-[1.2rem] bg-white/95 backdrop-blur-xl border border-black/8 shadow-[0_8px_30px_rgba(0,0,0,0.12)] p-[0.6rem] z-50"
        >
          {LOCALES.map((l) => (
            <a
              key={l}
              href={`/${l}`}
              hrefLang={LOCALE_META[l].hreflang}
              role="menuitem"
              className={`flex items-center justify-between px-[1.4rem] py-[1rem] rounded-[0.8rem] text-subhead transition-colors ${
                l === current
                  ? "text-black font-medium bg-black/[0.04]"
                  : "text-black/70 hover:bg-black/5"
              }`}
              onClick={() => setOpen(false)}
            >
              {LOCALE_META[l].name}
              {l === current && (
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
                  <path d="M5 12.5 10 17.5 19 6.5" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              )}
            </a>
          ))}
        </div>
      )}
    </div>
  );
}
