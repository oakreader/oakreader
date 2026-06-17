// Flattens Milkdown Crepe's stylesheet (src/oak-milkdown.css → its nested
// relative + package-specifier @imports) into a single
// ../../OakReader/Resources/Preview.bundle/js/oak-milkdown.css that the Swift host
// inlines into the WKWebView — mirroring oak-concept.css.
//
// postcss-import can't resolve the `@milkdown/kit/...` package-specifier @imports
// inside Crepe's CSS (they rely on the package's "exports" map), so we plug in a
// resolver backed by Node's require.resolve, which honours export maps. Relative
// imports fall through to postcss-import's default handling.
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import postcss from "postcss";
import atImport from "postcss-import";

const require = createRequire(import.meta.url);
const INPUT = "src/oak-milkdown.css";
const OUTPUT = "../../OakReader/Resources/Preview.bundle/js/oak-milkdown.css";

const css = readFileSync(INPUT, "utf8");
const result = await postcss([
  atImport({
    resolve(id, basedir) {
      if (!id.startsWith(".") && !id.startsWith("/")) {
        return require.resolve(id, { paths: [basedir] });
      }
      return id;
    },
  }),
]).process(css, { from: INPUT });

writeFileSync(OUTPUT, result.css);
console.log(`oak-milkdown.css written (${result.css.length} bytes)`);
