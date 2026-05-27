import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'

// Relative base so the built assets resolve under file:// inside WKWebView.
export default defineConfig({
  base: './',
  resolve: {
    alias: {
      // Consume the MiaoYan theme from our local Milkdown source build
      // (../milkdown/packages/crepe) instead of the npm package. The theme is
      // the only thing we changed in Crepe, and CSS has no dep-resolution risk,
      // so the editor JS stays on the proven npm crepe@7.21.1 (byte-identical
      // to our source build, which has no JS changes).
      '@milkdown/crepe/theme/miaoyan.css': fileURLToPath(
        new URL(
          '../../milkdown/packages/crepe/src/theme/miaoyan/style.css',
          import.meta.url
        )
      ),
    },
  },
  build: {
    outDir: 'dist',
    target: 'es2020',
  },
})
