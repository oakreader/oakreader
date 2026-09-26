"use client";

import { useEffect, useRef, useCallback } from "react";

/**
 * Adds a `data-revealed="true"` attribute when element scrolls into view.
 * CSS handles the actual transition — no JS opacity manipulation.
 */
export function useReveal<T extends HTMLElement>(
  options: { threshold?: number; rootMargin?: string } = {}
) {
  const ref = useRef<T>(null);
  const { threshold = 0.1, rootMargin = "0px 0px -50px 0px" } = options;

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          el.setAttribute("data-revealed", "true");
          observer.unobserve(el);
        }
      },
      { threshold, rootMargin }
    );

    observer.observe(el);
    return () => observer.disconnect();
  }, [threshold, rootMargin]);

  return ref;
}

/**
 * Reveals multiple children with stagger via CSS custom property.
 */
export function useRevealChildren<T extends HTMLElement>(
  childSelector: string,
  options: { threshold?: number; rootMargin?: string } = {}
) {
  const ref = useRef<T>(null);
  const { threshold = 0.1, rootMargin = "0px 0px -50px 0px" } = options;

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          const children = el.querySelectorAll(childSelector);
          children.forEach((child, i) => {
            (child as HTMLElement).style.setProperty(
              "--reveal-delay",
              `${i * 0.1}s`
            );
            child.setAttribute("data-revealed", "true");
          });
          observer.unobserve(el);
        }
      },
      { threshold, rootMargin }
    );

    observer.observe(el);
    return () => observer.disconnect();
  }, [childSelector, threshold, rootMargin]);

  return ref;
}
