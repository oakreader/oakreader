import resolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";
import terser from "@rollup/plugin-terser";

// Bundles defuddle + the oak entry into a single IIFE the native app injects into
// its live WKWebView (OakReader/Resources/Preview.bundle/js/oak-defuddle.js).
export default [
  {
    input: "src/oak-defuddle-entry.js",
    output: {
      file: "../OakReader/Resources/Preview.bundle/js/oak-defuddle.js",
      format: "iife",
    },
    plugins: [resolve({ browser: true }), commonjs(), terser()],
  },
];
