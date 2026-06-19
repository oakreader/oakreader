"use client";

// Deep imports (not the "@lobehub/icons" barrel): the barrel re-exports
// ./features → providerConfig → @lobehub/ui + antd, which breaks the static
// prerender in `next build` (works in dev, fails at build). Importing each icon
// by path pulls only that SVG component and keeps the bundle tiny.
import Claude from "@lobehub/icons/es/Claude";
import Cohere from "@lobehub/icons/es/Cohere";
import DeepSeek from "@lobehub/icons/es/DeepSeek";
import Gemini from "@lobehub/icons/es/Gemini";
import Grok from "@lobehub/icons/es/Grok";
import LmStudio from "@lobehub/icons/es/LmStudio";
import Meta from "@lobehub/icons/es/Meta";
import Mistral from "@lobehub/icons/es/Mistral";
import Ollama from "@lobehub/icons/es/Ollama";
import OpenAI from "@lobehub/icons/es/OpenAI";
import Perplexity from "@lobehub/icons/es/Perplexity";
import Qwen from "@lobehub/icons/es/Qwen";
import { useReveal } from "@/hooks/use-reveal";
import type { Dictionary } from "@/i18n/get-dictionary";

type IconComponent = React.ComponentType<{ size?: number }>;
type Provider = { name: string; Icon: IconComponent };

// Real brand marks via @lobehub/icons — each logo in its own brand color
// (.Color). OpenAI / Grok / Ollama / LM Studio ship mono-only marks (black by
// design, no color variant), so those use the default logo. Nominative use:
// shown to convey which models OakReader works with, no endorsement implied.
// Llama uses Meta's mark (it's a Meta model).
const row1: Provider[] = [
  { name: "Claude", Icon: Claude.Color },
  { name: "GPT", Icon: OpenAI },
  { name: "Gemini", Icon: Gemini.Color },
  { name: "Llama", Icon: Meta.Color },
  { name: "Mistral", Icon: Mistral.Color },
  { name: "DeepSeek", Icon: DeepSeek.Color },
];

const row2: Provider[] = [
  { name: "Grok", Icon: Grok },
  { name: "Qwen", Icon: Qwen.Color },
  { name: "Cohere", Icon: Cohere.Color },
  { name: "Perplexity", Icon: Perplexity.Color },
  { name: "Ollama (local)", Icon: Ollama },
  { name: "LM Studio (local)", Icon: LmStudio },
];

const edgeFade = {
  maskImage:
    "linear-gradient(90deg, transparent, black 10%, black 90%, transparent)",
  WebkitMaskImage:
    "linear-gradient(90deg, transparent, black 10%, black 90%, transparent)",
} as const;

function Chip({ name, Icon }: Provider) {
  return (
    <div className="shrink-0 inline-flex items-center gap-[1rem] bg-white border border-[#ededed] rounded-full px-[2rem] h-[5rem] shadow-[0_1px_3px_rgba(0,0,0,0.04),0_4px_12px_rgba(0,0,0,0.03)]">
      <Icon size={22} />
      <span className="font-sans font-medium text-[1.6rem] md:text-[1.7rem] text-black/70 whitespace-nowrap">
        {name}
      </span>
    </div>
  );
}

function MarqueeRow({
  items,
  duration,
  reverse = false,
}: {
  items: Provider[];
  duration: number;
  reverse?: boolean;
}) {
  return (
    <div className="overflow-hidden" style={edgeFade}>
      <div
        className="flex gap-[1.6rem] w-max"
        style={{
          animation: `marquee-left ${duration}s linear infinite`,
          animationDirection: reverse ? "reverse" : "normal",
        }}
      >
        {[...items, ...items].map((p, i) => (
          <Chip key={`${p.name}-${i}`} {...p} />
        ))}
      </div>
    </div>
  );
}

export function ModelMarquee({ dict }: { dict: Dictionary["models"] }) {
  const headingRef = useReveal<HTMLDivElement>();

  return (
    <section
      id="models"
      className="my-[8rem] md:my-[12rem] overflow-hidden"
    >
      <div
        ref={headingRef}
        data-reveal
        className="text-center px-[2rem] mb-[4rem] md:mb-[6rem] max-w-[120rem] mx-auto"
      >
        <p className="font-mono uppercase tracking-[0.1em] text-[1.2rem] text-black/35 mb-[1.6rem]">
          {dict.eyebrow}
        </p>
        <h2 className="font-exposure font-bold text-[3.2rem] md:text-[4rem] lg:text-[4.8rem] leading-[1.15] tracking-[-0.01em] text-balance">
          {dict.title}
        </h2>
        <p className="font-sans mt-[2.4rem] text-[1.7rem] md:text-[1.9rem] leading-[1.6] text-black/50 max-w-[46ch] mx-auto text-pretty">
          {dict.subhead}
        </p>
      </div>

      <div className="flex flex-col gap-[1.6rem]">
        <MarqueeRow items={row1} duration={42} />
        <MarqueeRow items={row2} duration={52} reverse />
      </div>
    </section>
  );
}
