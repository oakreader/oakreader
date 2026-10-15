import { copyFileSync, mkdirSync } from "node:fs";
import resolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";
import replace from "@rollup/plugin-replace";
import terser from "@rollup/plugin-terser";

// Bundles the genui widget runtime (React + htm + the oak entry) into one IIFE,
// and copies its HTML shell beside it. The native app loads
// app/Resources/Preview.bundle/genui/index.html into a WKWebView per widget.
const out = "../app/Resources/Preview.bundle/genui";

export default [
  {
    input: "src/oak-genui/entry.js",
    output: { file: `${out}/oak-genui.js`, format: "iife" },
    plugins: [
      replace({ preventAssignment: true, values: { "process.env.NODE_ENV": JSON.stringify("production") } }),
      resolve({ browser: true }),
      commonjs(),
      terser(),
      {
        name: "copy-shell",
        writeBundle() {
          mkdirSync(out, { recursive: true });
          copyFileSync("src/oak-genui/index.html", `${out}/index.html`);
        },
      },
    ],
  },
];
