"use client";

import { useState, useEffect } from "react";
import { motion, AnimatePresence } from "motion/react";
import Image from "next/image";
import Link from "next/link";
import { DOWNLOAD_URL } from "@/lib/links";
import { LocaleSwitcher } from "@/components/locale-switcher";
import { localeHome, type Locale } from "@/i18n/config";
import type { Dictionary } from "@/i18n/get-dictionary";

const navLinks: { label: string; href: string }[] = [];

export function Header({
  dict,
  locale,
}: {
  dict: Dictionary["nav"];
  locale: Locale;
}) {
  const home = localeHome(locale);
  const [scrolled, setScrolled] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);

  useEffect(() => {
    const handleScroll = () => setScrolled(window.scrollY > 50);
    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, []);

  return (
    <header className="print:hidden fixed top-[1.4rem] md:top-[2.8rem] left-[1rem] right-[1rem] flex flex-col items-center gap-y-[1rem] z-50">
      {/* Mobile nav */}
      <div className="md:hidden relative w-full">
        <div
          className={`w-full rounded-[1.6rem] backdrop-blur-xl flex items-center justify-between px-[0.6rem] h-[5.2rem] transition-all duration-500 ease-out ${
            scrolled
              ? "bg-white/90 border border-black/10 shadow-[0_2px_16px_rgba(0,0,0,0.08)]"
              : "bg-white/80 border border-black/8 shadow-sm"
          }`}
        >
          <Link
            href={home}
            className="flex items-center gap-[0.6rem] h-[4rem] px-[0.8rem]"
            aria-label="OakReader"
          >
            <OakLogo />
          </Link>
          <div className="flex items-center gap-[0.4rem]">
            <LocaleSwitcher current={locale} label={dict.language} />
            <XLink />
            <a
              href={DOWNLOAD_URL}
              className="inline-flex items-center justify-center h-[3.6rem] px-[1.4rem] rounded-[1rem] bg-black text-white text-footnote font-medium tracking-[-0.01em] cursor-pointer whitespace-nowrap"
            >
              {dict.download}
            </a>
            {navLinks.length > 0 && (
              <button
                onClick={() => setMobileOpen(!mobileOpen)}
                className="flex items-center justify-center w-[4rem] h-[4rem] rounded-[1rem] hover:bg-black/5 transition-colors"
              >
                <svg
                  width="20"
                  height="20"
                  viewBox="0 0 20 20"
                  fill="none"
                  className="text-label"
                >
                  <path
                    d="M3 5h14M3 10h14M3 15h14"
                    stroke="currentColor"
                    strokeWidth="1.5"
                    strokeLinecap="round"
                  />
                </svg>
              </button>
            )}
          </div>
        </div>
        <AnimatePresence>
          {mobileOpen && (
            <motion.div
              initial={{ opacity: 0, y: -10 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -10 }}
              className="absolute top-full mt-[0.8rem] w-full rounded-[1.6rem] bg-white/90 backdrop-blur-xl border border-black/8 shadow-lg p-[0.8rem]"
            >
              {navLinks.map((link) => (
                <Link
                  key={link.label}
                  href={link.href}
                  className="block px-[2rem] py-[1.2rem] text-subhead text-label-secondary hover:text-label rounded-[0.8rem] transition-colors"
                  onClick={() => setMobileOpen(false)}
                >
                  {link.label}
                </Link>
              ))}
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {/* Desktop nav */}
      <nav
        aria-label="Main navigation"
        className="hidden md:flex w-full items-center justify-center z-10 relative"
      >
        <motion.div
          className={`backdrop-blur-xl border rounded-[1.6rem] flex items-center h-[5.2rem] pl-[1.2rem] pr-[0.8rem] gap-[2rem] transition-all duration-500 ease-out ${
            scrolled
              ? "bg-white/90 border-black/10 shadow-[0_2px_16px_rgba(0,0,0,0.08)]"
              : "bg-white/80 border-black/8 shadow-sm"
          }`}
          initial={{ y: -20, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          transition={{ duration: 0.6, ease: [0.16, 1, 0.3, 1] }}
        >
          <Link
            href={home}
            className="flex items-center gap-[0.6rem] h-[4rem] px-[0.8rem] text-label transition-opacity duration-200 hover:opacity-70"
            aria-label="OakReader"
          >
            <OakLogo />
            <span className="text-subhead font-semibold tracking-[-0.02em]">OakReader</span>
          </Link>
          <ul className="flex gap-[1.6rem] items-center justify-center">
            {navLinks.map((link) => (
              <li key={link.label}>
                <Link
                  href={link.href}
                  className="text-subhead relative transition-opacity duration-200 hover:opacity-100 whitespace-nowrap opacity-70"
                >
                  {link.label}
                </Link>
              </li>
            ))}
          </ul>
          <div className="flex items-center gap-[0.4rem]">
            <LocaleSwitcher current={locale} label={dict.language} />
            <XLink />
          </div>
          <a
            href={DOWNLOAD_URL}
            className="inline-flex items-center justify-center h-[3.8rem] px-[1.6rem] rounded-[1.2rem] bg-black text-white text-callout font-medium tracking-[-0.01em] transition-all duration-200 hover:bg-black/85 cursor-pointer whitespace-nowrap"
          >
            {dict.download}
          </a>
        </motion.div>
      </nav>
    </header>
  );
}

const ICON_LINK_CLASS =
  "flex items-center justify-center w-[3.8rem] h-[3.8rem] rounded-[1.2rem] text-label-secondary hover:bg-black/5 transition-colors cursor-pointer";

function XLink() {
  return (
    <a
      href="https://x.com/JiweiYuan"
      target="_blank"
      rel="noopener noreferrer"
      aria-label="X (Twitter)"
      className={ICON_LINK_CLASS}
    >
      <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
        <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231 5.45-6.231Zm-1.161 17.52h1.833L7.084 4.126H5.117L17.083 19.77Z" />
      </svg>
    </a>
  );
}

function OakLogo() {
  return (
    <Image
      src="/icon.svg"
      alt="OakReader"
      width={28}
      height={28}
      className="rounded-[0.5rem]"
    />
  );
}
