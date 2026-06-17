// Builds ../../OakReader/Resources/Preview.bundle/js/oak-mindmap.css by
// concatenating Mind Elixir's stylesheet with KaTeX's, with KaTeX's woff2 fonts
// inlined as base64 data: URLs. The Swift host inlines this whole file into the
// WKWebView via loadHTMLString(baseURL: nil), under which the relative
// `url(fonts/…)` references KaTeX ships would resolve to nothing — so the fonts
// must be inlined. We keep only the woff2 source (all WebKit builds support it)
// and drop the woff/ttf fallbacks to halve the size.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const OUTPUT = "../../OakReader/Resources/Preview.bundle/js/oak-mindmap.css";

// Direct node_modules paths — both packages' "exports" maps hide their CSS
// subpaths from require.resolve, so we read the files straight off disk.
const mindElixirCss = readFileSync("node_modules/mind-elixir/dist/MindElixir.css", "utf8");

const katexDir = "node_modules/katex/dist";
let katexCss = readFileSync(join(katexDir, "katex.min.css"), "utf8");

// Drop woff/ttf fallback sources (keep only woff2).
katexCss = katexCss.replace(
  /\s*,\s*url\(fonts\/[^)]+\.(?:woff|ttf)\)\s*format\((?:"|')(?:woff|truetype)(?:"|')\)/g,
  ""
);

// Inline each woff2 font as a base64 data: URL.
let fontCount = 0;
katexCss = katexCss.replace(/url\(fonts\/([^)]+\.woff2)\)/g, (_m, file) => {
  const b64 = readFileSync(join(katexDir, "fonts", file)).toString("base64");
  fontCount += 1;
  return `url(data:font/woff2;base64,${b64})`;
});

const out = `${mindElixirCss}\n/* --- KaTeX (fonts inlined) --- */\n${katexCss}\n`;
writeFileSync(OUTPUT, out);
console.log(`oak-mindmap.css written (${out.length} bytes, ${fontCount} fonts inlined)`);
