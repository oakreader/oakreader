"use client";

import { useReveal } from "@/hooks/use-reveal";

type Provider = { name: string; color: string };

// Brand-ish accent per provider — gives each model a visual identity
// without depending on (trademarked) logo assets.
const row1: Provider[] = [
  { name: "Claude", color: "#D97757" },
  { name: "GPT", color: "#10A37F" },
  { name: "Gemini", color: "#4285F4" },
  { name: "Llama", color: "#0866FF" },
  { name: "Mistral", color: "#FA520F" },
  { name: "DeepSeek", color: "#4D6BFE" },
];

const row2: Provider[] = [
  { name: "Grok", color: "#111111" },
  { name: "Qwen", color: "#615CED" },
  { name: "Cohere", color: "#39594D" },
  { name: "Perplexity", color: "#20808D" },
  { name: "Ollama (local)", color: "#111111" },
  { name: "LM Studio (local)", color: "#4338CA" },
];

const edgeFade = {
  maskImage:
    "linear-gradient(90deg, transparent, black 10%, black 90%, transparent)",
  WebkitMaskImage:
    "linear-gradient(90deg, transparent, black 10%, black 90%, transparent)",
} as const;

function Chip({ name, color }: Provider) {
  return (
    <div className="shrink-0 inline-flex items-center gap-[1rem] bg-white border border-[#ededed] rounded-full px-[2rem] h-[5rem] shadow-[0_1px_3px_rgba(0,0,0,0.04),0_4px_12px_rgba(0,0,0,0.03)]">
      <span
        className="w-[1rem] h-[1rem] rounded-full shrink-0"
        style={{ backgroundColor: color }}
      />
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

export function ModelMarquee() {
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
          Model-agnostic
        </p>
        <h2 className="font-exposure font-bold text-[3.2rem] md:text-[4rem] lg:text-[4.8rem] leading-[1.15] tracking-[-0.01em] text-balance">
          Use any model. Switch anytime.
        </h2>
        <p className="font-sans mt-[2.4rem] text-[1.7rem] md:text-[1.9rem] leading-[1.6] text-black/50 max-w-[46ch] mx-auto text-pretty">
          The best brain for each question &mdash; from the frontier labs to a
          local model running on your Mac. Your choice, every time.
        </p>
      </div>

      <div className="flex flex-col gap-[1.6rem]">
        <MarqueeRow items={row1} duration={42} />
        <MarqueeRow items={row2} duration={52} reverse />
      </div>
    </section>
  );
}
