"use client";

import { motion } from "motion/react";
import { Button } from "@/components/ui/button";
import { DOWNLOAD_URL } from "@/lib/links";
import { WindowFrame } from "@/components/window-frame";

// Single static accent — the page stays calm. (Was a two-theme color cycle.)
const HERO_COLOR = "#79C9FF";
const HERO_GRADIENT = `radial-gradient(
  100vmax,
  rgba(0,0,0,0) 54.81%,
  rgb(255,172,227) 60.098%,
  rgba(255,241,172,0.5) 62.983%,
  rgb(121,201,255) 68.5%,
  rgb(74,96,209) 80%,
  rgb(80,146,199) 90%,
  rgb(60,106,255) 93%,
  rgb(86,86,86) 97%,
  rgba(0,0,0,0) 100%
)`;

function EarlyAccessBadge() {
  return (
    <div className="inline-flex items-center gap-[0.8rem] bg-white/70 backdrop-blur border border-[#ededed] rounded-full px-[1.6rem] h-[3.4rem] shadow-[0_1px_3px_rgba(0,0,0,0.04)] mb-[2.4rem]">
      <span className="relative flex h-[0.7rem] w-[0.7rem]">
        <span className="animate-ping absolute h-full w-full rounded-full bg-emerald-400 opacity-75" />
        <span className="relative rounded-full h-[0.7rem] w-[0.7rem] bg-emerald-500" />
      </span>
      <span className="text-[1.3rem] text-black/55 font-medium tracking-[0.01em]">
        Early Access &middot; macOS
      </span>
    </div>
  );
}

export function Hero() {
  return (
    <section
      className="relative overflow-clip bg-[#f8f8f8] isolate pb-[8rem] md:pb-[12rem]"
      style={{ "--hero-color": HERO_COLOR } as React.CSSProperties}
    >
      {/* Background: static gradient glow + white dome, pinned to the top viewport */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 top-0 h-[100svh] overflow-hidden -z-0"
      >
        <div
          className="absolute left-1/2 -translate-x-1/2 [clip-path:inset(0_0_33.33%_0)] blur-[20px] min-[600px]:blur-[40px]"
          style={{
            width: "210vmax",
            height: "210vmax",
            top: "calc(65vmax + 18svh)",
            backgroundImage: HERO_GRADIENT,
          }}
        />
        <div
          className="absolute left-1/2 -translate-x-1/2 aspect-square bg-[#f8f8f8] rounded-full [clip-path:inset(0_0_33.33%_0)]"
          style={{ width: "130vmax", top: "18svh" }}
        />
      </div>

      {/* Content — normal flow, the headline sits in the glow, the product shot anchors it */}
      <motion.div
        className="relative z-[2] flex flex-col items-center text-center px-[1.6rem] pt-[20svh] md:pt-[16svh]"
        initial={{ opacity: 0, y: 16 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.7, ease: [0.16, 1, 0.3, 1] }}
      >
        <EarlyAccessBadge />

        <p className="font-sans italic text-[1.4rem] min-[800px]:text-[1.6rem] text-black/40 tracking-[0.01em] mb-[1.6rem]">
          A research agent for everything you read.
        </p>

        <h1 className="flex flex-col items-center text-black leading-[1.1] tracking-[-0.02em] text-[3.2rem] min-[600px]:text-[4.8rem] min-[800px]:text-[6rem] min-[1000px]:text-[6.8rem]">
          <span className="font-exposure font-semibold whitespace-nowrap">
            Read everything.
          </span>
          <span className="font-exposure font-semibold whitespace-nowrap">
            Understand anything.
          </span>
        </h1>

        <p className="font-sans font-medium tracking-[-0.01em] text-[1.6rem] min-[600px]:text-[1.8rem] min-[800px]:text-[2.2rem] text-black/55 max-w-[30rem] min-[800px]:max-w-[48rem] leading-[150%] text-pretty mt-[3.2rem] md:mt-[4rem]">
          Keep everything you read in one place &mdash; then let an AI search
          and answer across all of it, with citations you can open.
        </p>

        {/* What you can bring — Heptabase-style source pills */}
        <div className="flex flex-wrap items-center justify-center gap-[0.8rem] mt-[2.4rem]">
          <span className="text-[1.3rem] text-black/35 font-medium mr-[0.4rem]">
            Bring your
          </span>
          {["PDFs", "Papers", "Web pages", "Books"].map((s) => (
            <span
              key={s}
              className="inline-flex items-center bg-white/70 backdrop-blur border border-[#ededed] rounded-full px-[1.4rem] h-[3.2rem] text-[1.3rem] font-medium text-black/60 shadow-[0_1px_3px_rgba(0,0,0,0.04)]"
            >
              {s}
            </span>
          ))}
        </div>

        <div className="flex flex-col items-center gap-[1.6rem] mt-[3.2rem] md:mt-[4rem]">
          <Button
            variant="ghost"
            className="rounded-[1.4rem] p-0 h-auto cursor-pointer hover:bg-transparent"
            nativeButton={false}
            render={<a href={DOWNLOAD_URL} />}
          >
            <span className="relative inline-flex items-center justify-center">
              <span
                className="relative flex items-center justify-center rounded-[1.4rem] text-white font-sans font-medium text-[1.8rem] min-[800px]:text-[2rem] h-[5.6rem] w-[28rem] hover:opacity-85 transition-opacity"
                style={{
                  backgroundColor: `color-mix(in srgb, ${HERO_COLOR} 8%, #0a0a0a)`,
                  boxShadow: `inset 0 1px 0 0 color-mix(in srgb, ${HERO_COLOR} 55%, transparent)`,
                }}
              >
                Download for Free
              </span>
            </span>
          </Button>
          <p className="font-sans text-[1.3rem] min-[800px]:text-[1.4rem] text-black/35 tracking-[0.02em]">
            Available on macOS &middot; No credit card required
          </p>
        </div>

        {/* Signature product shot — one big, legible window */}
        <div className="w-full max-w-[100rem] mt-[6rem] md:mt-[9rem]">
          <WindowFrame
            src="/shots/ai-agent.png"
            alt="Oak answering a question in context with rendered math and markdown"
            priority
          />
        </div>
      </motion.div>
    </section>
  );
}
