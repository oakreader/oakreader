"use client";

import { useReveal } from "@/hooks/use-reveal";
import { WindowFrame } from "@/components/window-frame";

// Heptabase-style bento: centered section header, then a 2-column grid of
// rounded cards — each an eyebrow label + one-liner + a real product shot.
const cards = [
  {
    eyebrow: "Ask",
    title: "Read between the lines",
    desc: "Open any document and ask Oak what it means — answered in context with formatted notes, code, and rendered math.",
    image: "/shots/ai-agent.png",
    alt: "Oak answering a question in context with rendered math and markdown",
    tint: "from-sky-50 to-indigo-50",
  },
  {
    eyebrow: "Browse",
    title: "The web, without leaving",
    desc: "Search, open a link, or just ask the AI in a new tab. Read live pages with your logins intact, then capture what matters.",
    image: "/shots/browser-search.png",
    alt: "Oak's in-app browser new-tab search routing to the web or the AI",
    tint: "from-emerald-50 to-teal-50",
  },
  {
    eyebrow: "Library",
    title: "Everything you keep, searchable",
    desc: "Every PDF, article, and web snapshot in collections and tags — full-text search that even understands 中日韩.",
    image: "/shots/library.png",
    alt: "Oak's library with collections, tags, and full-text search",
    tint: "from-violet-50 to-fuchsia-50",
  },
  {
    eyebrow: "OakAI",
    title: "A partner that read it all",
    desc: "Chat with an assistant that knows your whole library and answers with citations you can open and check.",
    image: "/shots/ai-chat.png",
    alt: "Oak's OakAI assistant answering from across the library",
    tint: "from-amber-50 to-orange-50",
  },
];

function Heading() {
  const ref = useReveal<HTMLDivElement>();
  return (
    <div ref={ref} data-reveal className="text-center max-w-[64rem] mx-auto">
      <p className="font-mono uppercase tracking-[0.1em] text-[1.2rem] text-black/35 mb-[1.6rem]">
        Context Library
      </p>
      <h2 className="font-exposure font-bold text-[3.2rem] md:text-[4rem] lg:text-[4.8rem] leading-[1.15] tracking-[-0.01em] text-balance">
        Your sources, notes, and answers in one place.
      </h2>
    </div>
  );
}

function Card({ card, index }: { card: (typeof cards)[number]; index: number }) {
  const ref = useReveal<HTMLDivElement>();
  return (
    <div
      ref={ref}
      data-reveal
      style={{ "--reveal-delay": `${(index % 2) * 0.08}s` } as React.CSSProperties}
      className={`rounded-[2rem] md:rounded-[2.8rem] border border-black/8 bg-gradient-to-br ${card.tint} p-[2.4rem] md:p-[3.2rem]`}
    >
      <span className="block font-mono text-[1.2rem] uppercase tracking-[0.1em] text-black/40 mb-[1.2rem]">
        {card.eyebrow}
      </span>
      <h3 className="font-exposure font-bold text-[2.4rem] md:text-[2.8rem] leading-[1.15] tracking-[-0.01em] text-black">
        {card.title}
      </h3>
      <p className="font-sans mt-[1.2rem] text-[1.6rem] md:text-[1.7rem] leading-[1.6] text-black/55 max-w-[46ch]">
        {card.desc}
      </p>
      <div className="mt-[2.4rem] md:mt-[3.2rem]">
        <WindowFrame src={card.image} alt={card.alt} />
      </div>
    </div>
  );
}

export function Bento() {
  return (
    <section
      id="features"
      className="max-w-[120rem] mx-auto px-[2rem] mt-[10rem] md:mt-[14rem]"
    >
      <Heading />
      <div className="grid md:grid-cols-2 gap-[2rem] md:gap-[2.4rem] mt-[5rem] md:mt-[6rem]">
        {cards.map((c, i) => (
          <Card key={c.title} card={c} index={i} />
        ))}
      </div>
    </section>
  );
}
