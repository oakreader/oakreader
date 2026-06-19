// The screenshots already include the macOS window chrome (traffic lights),
// so we just frame them with rounded corners, a hairline border, and a soft
// shadow to lift them off the page.
export function WindowFrame({
  src,
  alt,
  priority = false,
}: {
  src: string;
  alt: string;
  priority?: boolean;
}) {
  return (
    <div className="rounded-[1.2rem] md:rounded-[1.8rem] overflow-hidden border border-black/10 bg-white shadow-[0_2px_8px_rgba(0,0,0,0.06),0_40px_90px_-28px_rgba(0,0,0,0.25)]">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        src={src}
        alt={alt}
        loading={priority ? "eager" : "lazy"}
        className="w-full h-auto block"
      />
    </div>
  );
}
