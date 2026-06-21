"use client";

import { motion } from "motion/react";
import { Button } from "@/components/ui/button";
import { DOWNLOAD_URL } from "@/lib/links";
import { WindowFrame } from "@/components/window-frame";
import type { Dictionary } from "@/i18n/get-dictionary";

type HeroDict = Dictionary["hero"];

// Single static accent — the page stays calm. (Was a two-theme color cycle.)
const HERO_COLOR = "#79C9FF";
// Apple-style: near-white, a single restrained cool bloom — no saturated rainbow.
const HERO_GRADIENT = `radial-gradient(
  100vmax,
  rgba(0,0,0,0) 60%,
  rgba(206,222,245,0.40) 73%,
  rgba(224,230,239,0.55) 84%,
  rgba(198,207,221,0.28) 93%,
  rgba(0,0,0,0) 100%
)`;

export function Hero({ dict }: { dict: HeroDict }) {
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
        <p className="font-sans italic text-callout min-[800px]:text-subhead text-label-tertiary tracking-[0.01em] mb-[1.6rem]">
          {dict.tagline}
        </p>

        <h1 className="flex flex-col items-center text-label leading-[1.1] tracking-[-0.02em] text-title1 min-[600px]:text-display min-[800px]:text-display-lg min-[1000px]:text-display-xl">
          <span className="font-exposure font-semibold whitespace-nowrap">
            {dict.headline1}
          </span>
          <span className="font-exposure font-semibold whitespace-nowrap">
            {dict.headline2}
          </span>
        </h1>

        <p className="font-sans font-medium tracking-[-0.01em] text-subhead min-[600px]:text-body min-[800px]:text-lead text-label-secondary max-w-[30rem] min-[800px]:max-w-[48rem] leading-[150%] text-pretty mt-[3.2rem] md:mt-[4rem]">
          {dict.subhead}
        </p>

        {/* What you can bring — Heptabase-style source pills */}
        <div className="flex flex-wrap items-center justify-center gap-[0.8rem] mt-[2.4rem]">
          <span className="text-footnote text-label-tertiary font-medium mr-[0.4rem]">
            {dict.bringYour}
          </span>
          {dict.pills.map((s) => (
            <span
              key={s}
              className="inline-flex items-center bg-white/70 backdrop-blur border border-[#ededed] rounded-full px-[1.4rem] h-[3.2rem] text-footnote font-medium text-label-secondary shadow-[0_1px_3px_rgba(0,0,0,0.04)]"
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
                className="relative flex items-center justify-center overflow-hidden rounded-[1.6rem] text-white font-sans font-medium text-body min-[800px]:text-lead h-[5.6rem] w-[28rem] border border-white/15 backdrop-blur-xl transition-[transform,box-shadow] duration-300 ease-out hover:scale-[1.02] active:scale-[0.99]"
                style={{
                  backgroundColor: `color-mix(in srgb, ${HERO_COLOR} 4%, rgba(9,9,11,0.98))`,
                  boxShadow: [
                    "inset 0 1px 0.5px 0 rgba(255,255,255,0.45)", // top specular highlight
                    "inset 0 0 0 0.5px rgba(255,255,255,0.08)", // inner rim
                    "inset 0 -8px 16px -8px rgba(0,0,0,0.5)", // bottom inner shade
                    "0 10px 30px -6px rgba(0,0,0,0.30)", // soft drop
                    "0 2px 6px rgba(0,0,0,0.18)",
                  ].join(", "),
                }}
              >
                {/* glossy sheen — the "liquid" curved highlight on the top half */}
                <span
                  aria-hidden="true"
                  className="pointer-events-none absolute inset-x-0 top-0 h-1/2 rounded-t-[1.6rem] bg-gradient-to-b from-white/22 to-transparent"
                />
                <span className="relative">{dict.cta}</span>
              </span>
            </span>
          </Button>
          <p className="font-sans text-footnote min-[800px]:text-callout text-label-tertiary tracking-[0.02em]">
            {dict.ctaNote}
          </p>
        </div>

        {/* Signature product shot — one big, legible window */}
        <div className="w-full max-w-[100rem] mt-[6rem] md:mt-[9rem]">
          <WindowFrame
            src="/shots/ai-agent.png"
            alt={dict.shotAlt}
            priority
          />
        </div>
      </motion.div>
    </section>
  );
}
