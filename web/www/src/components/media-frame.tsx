"use client";

import { useEffect, useRef, useSyncExternalStore } from "react";

const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)";

// Reduced-motion preference as an external store — avoids setState-in-effect and
// stays correct across SSR (server snapshot = false, i.e. animate by default).
function useReducedMotion() {
  return useSyncExternalStore(
    (onChange) => {
      const mq = window.matchMedia(REDUCED_MOTION_QUERY);
      mq.addEventListener("change", onChange);
      return () => mq.removeEventListener("change", onChange);
    },
    () => window.matchMedia(REDUCED_MOTION_QUERY).matches,
    () => false
  );
}

// The video clips (ScreenStudio recordings) already include the macOS window
// chrome, so — like WindowFrame — we just lift them off the page with rounded
// corners, a hairline border, and a soft shadow. A short, muted, looping clip
// reads as a "living screenshot": it plays only while on-screen, and falls back
// to the poster frame for visitors who prefer reduced motion.
export function MediaFrame({
  src,
  poster,
  alt,
  priority = false,
  cropBottomPct = 0,
}: {
  /** Base path without extension, e.g. "/demo/hero". Loads .webm + .mp4. */
  src: string;
  /** Poster image path, e.g. "/demo/hero.jpg". */
  poster: string;
  alt: string;
  priority?: boolean;
  /**
   * Trim a sliver off the bottom edge, as a percentage of the frame width.
   * The ScreenStudio clips bleed a thin gradient strip of recording background
   * along their bottom edge; clipping ~2% hides it. Percentage margins are
   * resolved against width, so this stays scale-invariant. 0 = no trim.
   */
  cropBottomPct?: number;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const reducedMotion = useReducedMotion();

  // Only play while the clip is in view — pause it once it scrolls away so we
  // never burn cycles decoding off-screen video.
  useEffect(() => {
    const el = videoRef.current;
    if (!el || reducedMotion) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          el.play().catch(() => {});
        } else {
          el.pause();
        }
      },
      { threshold: 0.25 }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, [reducedMotion]);

  const cropStyle =
    cropBottomPct > 0 ? { marginBottom: `-${cropBottomPct}%` } : undefined;

  return (
    <div className="rounded-[0.8rem] md:rounded-[1.1rem] overflow-hidden border border-black/10 bg-white shadow-[0_2px_8px_rgba(0,0,0,0.06),0_40px_90px_-28px_rgba(0,0,0,0.25)]">
      {reducedMotion ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={poster} alt={alt} className="w-full h-auto block" style={cropStyle} />
      ) : (
        <video
          ref={videoRef}
          className="w-full h-auto block"
          style={cropStyle}
          poster={poster}
          aria-label={alt}
          muted
          loop
          playsInline
          autoPlay
          preload={priority ? "auto" : "metadata"}
        >
          <source src={`${src}.webm`} type="video/webm" />
          <source src={`${src}.mp4`} type="video/mp4" />
        </video>
      )}
    </div>
  );
}
