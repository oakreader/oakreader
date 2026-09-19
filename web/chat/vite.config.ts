import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { viteSingleFile } from "vite-plugin-singlefile";
import { fileURLToPath } from "node:url";

// One self-contained index.html: a WKWebView loads it straight from the app
// bundle with loadFileURL, so there is no local server, no CORS, and no
// relative-asset resolution to get wrong.
export default defineConfig({
  plugins: [react(), tailwindcss(), viteSingleFile()],
  resolve: {
    // t3code's sources import through "~/", which their app maps to src/.
    // Point it at the vendored tree so copied files resolve unmodified.
    alias: { "~": fileURLToPath(new URL("./src/vendor/t3code", import.meta.url)) },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "safari18", // matches MACOSX_DEPLOYMENT_TARGET 15.4's WebKit
    assetsInlineLimit: 100_000_000,
    chunkSizeWarningLimit: 4096,
  },
});
