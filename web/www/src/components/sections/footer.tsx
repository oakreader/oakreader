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
          <div className="text-center text-label-secondary">
            <p className="normal-case tracking-normal">
              {dict.builtBy}
              <br />
              <a
                href="#"
                className="text-label-secondary hover:text-label transition-colors"
              >
                Oak
              </a>
            </p>
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
              <a
                href="https://github.com/oakreader/oakreader"
                target="_blank"
                rel="noopener noreferrer"
                aria-label="GitHub"
                className="text-label-secondary hover:text-label transition-colors"
              >
                <svg width="17" height="17" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                  <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.108-.776.417-1.305.76-1.605-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.51 11.51 0 0 1 12 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222 0 1.606-.014 2.898-.014 3.293 0 .322.216.694.825.576C20.565 22.092 24 17.595 24 12.297c0-6.627-5.373-12-12-12Z" />
                </svg>
              </a>
            </div>
          </div>
        </div>
      </div>
    </footer>
  );
}
