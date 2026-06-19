"use client";

import { useReveal } from "@/hooks/use-reveal";
import { WindowFrame } from "@/components/window-frame";
import type { Dictionary } from "@/i18n/get-dictionary";

type BentoDict = Dictionary["bento"];
type CardContent = BentoDict["cards"][keyof BentoDict["cards"]];

// Heptabase-style bento: centered section header, then a 2-column grid of
// rounded cards — each an eyebrow label + one-liner + a real product shot.
// Layout (image + gradient tint) lives here; all copy comes from the locale
// dictionary, keyed by `key`.
const cardLayout = [
  { key: "ask", image: "/shots/ai-agent.png", tint: "from-sky-50 to-indigo-50" },
  { key: "browse", image: "/shots/browser-search.png", tint: "from-emerald-50 to-teal-50" },
  { key: "library", image: "/shots/library.png", tint: "from-violet-50 to-fuchsia-50" },
  { key: "oakai", image: "/shots/ai-chat.png", tint: "from-amber-50 to-orange-50" },
] as const;

function Heading({ dict }: { dict: BentoDict }) {
  const ref = useReveal<HTMLDivElement>();
  return (
    <div ref={ref} data-reveal className="text-center max-w-[64rem] mx-auto">
      <p className="font-mono uppercase tracking-[0.1em] text-[1.2rem] text-black/35 mb-[1.6rem]">
        {dict.eyebrow}
      </p>
      <h2 className="font-exposure font-bold text-[3.2rem] md:text-[4rem] lg:text-[4.8rem] leading-[1.15] tracking-[-0.01em] text-balance">
        {dict.title}
      </h2>
    </div>
  );
}

function Card({
  layout,
  content,
  index,
}: {
  layout: (typeof cardLayout)[number];
  content: CardContent;
  index: number;
}) {
  const ref = useReveal<HTMLDivElement>();
  return (
    <div
      ref={ref}
      data-reveal
      style={{ "--reveal-delay": `${(index % 2) * 0.08}s` } as React.CSSProperties}
      className={`rounded-[2rem] md:rounded-[2.8rem] border border-black/8 bg-gradient-to-br ${layout.tint} p-[2.4rem] md:p-[3.2rem]`}
    >
      <span className="block font-mono text-[1.2rem] uppercase tracking-[0.1em] text-black/40 mb-[1.2rem]">
        {content.eyebrow}
      </span>
      <h3 className="font-exposure font-bold text-[2.4rem] md:text-[2.8rem] leading-[1.15] tracking-[-0.01em] text-black">
        {content.title}
      </h3>
      <p className="font-sans mt-[1.2rem] text-[1.6rem] md:text-[1.7rem] leading-[1.6] text-black/55 max-w-[46ch]">
        {content.desc}
      </p>
      <div className="mt-[2.4rem] md:mt-[3.2rem]">
        <WindowFrame src={layout.image} alt={content.alt} />
      </div>
    </div>
  );
}

export function Bento({ dict }: { dict: BentoDict }) {
  return (
    <section
      id="features"
      className="max-w-[120rem] mx-auto px-[2rem] mt-[10rem] md:mt-[14rem]"
    >
      <Heading dict={dict} />
      <div className="grid md:grid-cols-2 gap-[2rem] md:gap-[2.4rem] mt-[5rem] md:mt-[6rem]">
        {cardLayout.map((c, i) => (
          <Card key={c.key} layout={c} content={dict.cards[c.key]} index={i} />
        ))}
      </div>
    </section>
  );
}
