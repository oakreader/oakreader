import resolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";
import terser from "@rollup/plugin-terser";

// Bundles Mind Elixir (+ its plaintext converter) and the oak entry into a single
// IIFE the native app injects into a WKWebView
// (OakReader/Resources/Preview.bundle/js/oak-mindmap.js). Exposes
// window.oakMindmap.{render,update,getOutline}. Mind Elixir's stylesheet is copied
// alongside as oak-mindmap.css (see the build:mindmap script) and inlined by
// StudioWebView.
export default [
  {
    input: "src/oak-mindmap-entry.js",
    output: {
      file: "../OakReader/Resources/Preview.bundle/js/oak-mindmap.js",
      format: "iife",
    },
    plugins: [resolve({ browser: true }), commonjs(), terser()],
  },
];
