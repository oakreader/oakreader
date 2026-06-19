"use client";

import { useReveal } from "@/hooks/use-reveal";

// Modeled on Heptabase's "All the essentials" — barely-there warm-paper panels
// (no shadow, hairline border, small radius), a small monochrome line icon, a
// medium title, and a muted description. Restraint is the whole point.
const items = [
  {
    title: "Native & fast",
    desc: "Built for macOS — opens instantly and scrolls smoothly, even with thousands of documents.",
    icon: (
      <path
        d="M13 2 4 14h7l-1 8 9-12h-7l1-8Z"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    title: "Offline-first",
    desc: "Your library lives on your Mac. Read, search, and annotate without a connection.",
    icon: (
      <path
        d="M4 14a4 4 0 0 1 .9-7.9A5.5 5.5 0 0 1 16 7a4.5 4.5 0 0 1 .5 8.95M9 13l3 3 3-3M12 16V9"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    title: "Cite & check",
    desc: "Every answer points back to the exact source — open any citation and verify it yourself.",
    icon: (
      <path
        d="M9 17H7A4 4 0 0 1 7 9h2m6 8h2a4 4 0 0 0 0-8h-2M8 13h8"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
  {
    title: "Full-text search",
    desc: "Find any line across everything you keep — including 中文, 日本語, and 한국어.",
    icon: (
      <path
        d="M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14ZM21 21l-5-5"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    ),
  },
];

export function Essentials() {
  const ref = useReveal<HTMLDivElement>();
  return (
    <section className="max-w-[120rem] mx-auto px-[2rem] mt-[10rem] md:mt-[14rem]">
      <div ref={ref} data-reveal className="text-center max-w-[64rem] mx-auto">
        <p className="font-mono uppercase tracking-[0.1em] text-[1.2rem] text-black/35 mb-[1.6rem]">
          The essentials
        </p>
        <h2 className="font-exposure font-bold text-[3.2rem] md:text-[4rem] lg:text-[4.8rem] leading-[1.15] tracking-[-0.01em] text-balance">
          All the essentials, done right.
        </h2>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-[1.2rem] mt-[5rem] md:mt-[6rem]">
        {items.map((it, i) => (
          <Item key={it.title} item={it} index={i} />
        ))}
      </div>
    </section>
  );
}

function Item({ item, index }: { item: (typeof items)[number]; index: number }) {
  const ref = useReveal<HTMLDivElement>();
  return (
    <div
      ref={ref}
      data-reveal
      style={{ "--reveal-delay": `${index * 0.06}s` } as React.CSSProperties}
      className="h-full rounded-[0.8rem] border border-black/[0.04] bg-[#f0f0ea] px-[2rem] py-[2.2rem]"
    >
      <svg
        width="22"
        height="22"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        className="text-[#2e2e2e] mb-[1.6rem]"
      >
        {item.icon}
      </svg>
      <h3 className="font-sans font-medium text-[2rem] leading-[1.35] tracking-[-0.01em] text-[#2e2e2e]">
        {item.title}
      </h3>
      <p className="font-sans mt-[0.6rem] text-[1.6rem] leading-[1.5] text-black/[0.48]">
        {item.desc}
      </p>
    </div>
  );
}
