import type { Dictionary } from "@/i18n/get-dictionary";

export function Footer({ dict }: { dict: Dictionary["footer"] }) {
  return (
    <footer role="contentinfo" className="relative z-[1]">
      <div className="max-w-[120rem] mx-auto px-[2rem]">
        <div className="flex flex-col md:flex-row items-center justify-between font-mono uppercase text-footnote leading-[1.6rem] tracking-[0.1em] py-[2rem] gap-y-[2.4rem] border-t border-black/10">
          <div className="hidden lg:flex gap-[4rem] items-baseline text-label-secondary">
            <small>{dict.copyright}</small>
            <small>&copy; 2026</small>
          </div>
          <div className="flex items-center gap-[2rem] text-label-secondary">
            <small className="lg:hidden">{dict.copyright} &copy; 2026</small>
            <div className="flex items-center gap-[1.6rem]">
              <a
                href="https://x.com/JiweiYuan"
                target="_blank"
                rel="noopener noreferrer"
                aria-label="X (Twitter)"
                className="text-label-secondary hover:text-label transition-colors"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                  <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231 5.45-6.231Zm-1.161 17.52h1.833L7.084 4.126H5.117L17.083 19.77Z" />
                </svg>
              </a>
            </div>
          </div>
        </div>
      </div>
    </footer>
  );
}
