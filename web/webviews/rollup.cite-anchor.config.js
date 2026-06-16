import resolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";
import terser from "@rollup/plugin-terser";

// Bundles dom-anchor-text-quote (+ diff-match-patch) and the oak entry into a single
// IIFE the native app injects into its WKWebView
// (OakReader/Resources/Preview.bundle/js/oak-cite-anchor.js). Exposes
// window.oakHighlightCitation(), called by WebViewCoordinator to anchor + flash an
// AI-chat citation quote in the rendered page.
export default [
  {
    input: "src/oak-cite-anchor-entry.js",
    output: {
      file: "../../OakReader/Resources/Preview.bundle/js/oak-cite-anchor.js",
      format: "iife",
    },
    plugins: [resolve({ browser: true }), commonjs(), terser()],
  },
];
