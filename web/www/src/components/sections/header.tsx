"use client";

import { useState, useEffect } from "react";
import { motion, AnimatePresence } from "motion/react";
import Image from "next/image";
import Link from "next/link";
import { DOWNLOAD_URL } from "@/lib/links";

const navLinks: { label: string; href: string }[] = [];

export function Header() {
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
            href="/"
            className="flex items-center gap-[0.6rem] h-[4rem] px-[0.8rem]"
            aria-label="OakReader"
          >
            <OakLogo />
          </Link>
          <div className="flex items-center gap-[0.8rem]">
            <a
              href={DOWNLOAD_URL}
              className="inline-flex items-center justify-center h-[3.6rem] px-[1.4rem] rounded-[1rem] bg-black text-white text-[1.3rem] font-medium tracking-[-0.01em] cursor-pointer whitespace-nowrap"
            >
              Download
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
                  className="text-black"
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
                  className="block px-[2rem] py-[1.2rem] text-[1.6rem] text-black/70 hover:text-black rounded-[0.8rem] transition-colors"
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
          className={`backdrop-blur-xl border rounded-[1.6rem] flex items-center h-[5.2rem] pl-[0.6rem] pr-[0.6rem] gap-[1.2rem] transition-all duration-500 ease-out ${
            scrolled
              ? "bg-white/90 border-black/10 shadow-[0_2px_16px_rgba(0,0,0,0.08)]"
              : "bg-white/80 border-black/8 shadow-sm"
          }`}
          initial={{ y: -20, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          transition={{ duration: 0.6, ease: [0.16, 1, 0.3, 1] }}
        >
          <Link
            href="/"
            className="flex items-center gap-[0.6rem] h-[4rem] px-[0.8rem] text-black transition-opacity duration-200 hover:opacity-70"
            aria-label="OakReader"
          >
            <OakLogo />
            <span className="text-[1.6rem] font-semibold tracking-[-0.02em]">OakReader</span>
          </Link>
          <ul className="flex gap-[1.6rem] items-center justify-center">
            {navLinks.map((link) => (
              <li key={link.label}>
                <Link
                  href={link.href}
                  className="text-[1.6rem] relative transition-opacity duration-200 hover:opacity-100 whitespace-nowrap opacity-70"
                >
                  {link.label}
                </Link>
              </li>
            ))}
          </ul>
          <a
            href={DOWNLOAD_URL}
            className="inline-flex items-center justify-center ml-[0.4rem] h-[3.8rem] px-[1.6rem] rounded-[1.2rem] bg-black text-white text-[1.4rem] font-medium tracking-[-0.01em] transition-all duration-200 hover:bg-black/85 cursor-pointer whitespace-nowrap"
          >
            Download
          </a>
        </motion.div>
      </nav>
    </header>
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
