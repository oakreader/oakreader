"use client";

import { useReveal } from "@/hooks/use-reveal";
import { MediaFrame } from "@/components/media-frame";
import type { Dictionary } from "@/i18n/get-dictionary";

type BentoDict = Dictionary["bento"];
type CardContent = BentoDict["cards"][keyof BentoDict["cards"]];

// Heptabase-style bento: centered section header, then a 2-column grid of
// rounded cards — each an eyebrow label + one-liner + a short looping product
// clip. Layout (clip + gradient tint) lives here; all copy comes from the
// locale dictionary, keyed by `key`.
const cardLayout = [
  { key: "library", media: "/demo/library" },
  { key: "aichat", media: "/demo/aichat" },
  { key: "translate", media: "/demo/translate" },
  { key: "define", media: "/demo/wordcard" },
  { key: "notes", media: "/demo/notes" },
  { key: "browse", media: "/demo/browser" },
] as const;

function Heading({ dict }: { dict: BentoDict }) {
  const ref = useReveal<HTMLDivElement>();
  return (
    <div ref={ref} data-reveal className="text-center max-w-[64rem] mx-auto">
      <p className="font-mono uppercase tracking-[0.1em] text-caption text-label-tertiary mb-[1.6rem]">
        {dict.eyebrow}
      </p>
      <h2 className="font-exposure font-bold text-title1 md:text-display-sm lg:text-display leading-[1.15] tracking-[-0.01em] text-balance">
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
      className="flex flex-col rounded-[2rem] md:rounded-[2.8rem] border border-black/[0.055] bg-gradient-to-b from-[#fdfdfe] to-[#f1f1f4] p-[2.4rem] md:p-[3.2rem] shadow-[inset_0_1px_0_rgba(255,255,255,0.7),0_1px_2px_rgba(0,0,0,0.04),0_24px_48px_-30px_rgba(0,0,0,0.18)]"
    >
      <span className="block font-mono text-caption uppercase tracking-[0.1em] text-label-tertiary mb-[1.2rem]">
        {content.eyebrow}
      </span>
      <h3 className="font-exposure font-bold text-title3 md:text-title2 leading-[1.15] tracking-[-0.01em] text-label">
        {content.title}
      </h3>
      <p className="font-sans mt-[1.2rem] text-subhead md:text-body leading-[1.6] text-label-secondary max-w-[46ch]">
        {content.desc}
      </p>
      <div className="mt-auto pt-[2.4rem] md:pt-[3.2rem]">
        <MediaFrame
          src={layout.media}
          poster={`${layout.media}.jpg`}
          alt={content.alt}
          cropBottomPct={2}
        />
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
