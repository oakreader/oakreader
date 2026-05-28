import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'

// Builds the editor into the OakEditor Swift package's Resources, where it
// ships as Milkdown.bundle and is loaded at runtime via Bundle.module.
//
// Relative base so the built assets resolve under file:// inside WKWebView.
// The type.baby theme + PT Serif/PT Mono fonts are vendored under src/, so the
// build is fully self-contained.

// WKWebView loads the bundle from file://. Vite tags the module <script> and
// preload <link> with `crossorigin`, which forces a CORS fetch that fails for
// the opaque file:// origin — the module then silently never executes (blank
// editor). Strip the attribute so file:// module loading works.
function stripCrossorigin(): Plugin {
  return {
    name: 'oak-strip-crossorigin',
    transformIndexHtml(html) {
      return html.replace(/\s+crossorigin(?:=("|')[^"']*\1)?/g, '')
    },
  }
}

export default defineConfig({
  base: './',
  plugins: [stripCrossorigin()],
  build: {
    outDir: fileURLToPath(new URL('../Sources/OakEditor/Resources/Milkdown.bundle', import.meta.url)),
    emptyOutDir: true,
    target: 'es2020',
    modulePreload: { polyfill: false },
  },
})
