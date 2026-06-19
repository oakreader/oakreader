export function Footer() {
  return (
    <footer role="contentinfo" className="relative z-[1]">
      <div className="max-w-[120rem] mx-auto px-[2rem]">
        <div className="flex flex-col md:flex-row items-center justify-between font-mono uppercase text-[1.3rem] leading-[1.6rem] tracking-[0.1em] py-[2rem] gap-y-[2.4rem] border-t border-black/10">
          <div className="hidden lg:flex gap-[4rem] items-baseline text-black/50">
            <small>Copyright</small>
            <small>&copy; 2026</small>
          </div>
          <div className="text-center text-black/50">
            <p className="normal-case tracking-normal">
              Designed and Built by
              <br />
              <a
                href="#"
                className="text-black/70 hover:text-black transition-colors"
              >
                Oak
              </a>
            </p>
          </div>
          <div className="lg:hidden flex flex-wrap justify-center gap-x-[4rem] gap-y-[2.4rem] text-black/50">
            <small>Copyright &copy; 2026</small>
          </div>
        </div>
      </div>
    </footer>
  );
}
