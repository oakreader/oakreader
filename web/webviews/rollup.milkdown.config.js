import resolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";
import replace from "@rollup/plugin-replace";
import terser from "@rollup/plugin-terser";

// Bundles Milkdown Crepe (+ the oak entry) into a single IIFE the native app
// injects into a WKWebView
// (OakReader/Resources/Preview.bundle/js/oak-milkdown.js). Exposes
// window.oakMilkdown.{init,getMarkdown,setMarkdown,clear,focus,cmd,insertImage}.
// Crepe's stylesheet is built separately into oak-milkdown.css (see the
// build:milkdown script) and inlined by the Swift host, mirroring oak-mindmap.
export default [
  {
    input: "src/oak-milkdown-entry.js",
    output: {
      file: "../../OakReader/Resources/Preview.bundle/js/oak-milkdown.js",
      format: "iife",
      // Crepe lazy-loads some features via dynamic import; a single inlined IIFE
      // (no code-splitting) is what the WKWebView host injects.
      inlineDynamicImports: true,
    },
    plugins: [
      // Milkdown's deps (Vue's @vue/shared, etc.) branch on process.env.NODE_ENV,
      // which is undefined in a WKWebView — without this the bundle throws before
      // it defines window.oakMilkdown. Baking in "production" also strips dev-only
      // warning code.
      replace({
        preventAssignment: true,
        values: { "process.env.NODE_ENV": JSON.stringify("production") },
      }),
      resolve({ browser: true }),
      commonjs(),
      terser(),
    ],
  },
];
