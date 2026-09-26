import { defineConfig } from "wxt";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  modules: ["@wxt-dev/module-react"],
  vite: () => ({
    plugins: [tailwindcss()],
  }),
  manifest: {
    name: "OakReader",
    description: "Save web pages and articles to OakReader",
    permissions: ["activeTab", "scripting", "tabs", "webRequest", "cookies", "debugger", "storage"],
    // 23119 = release build, 23120 = Debug build (see src/lib/server.ts).
    host_permissions: [
      "http://127.0.0.1:23119/*",
      "http://127.0.0.1:23120/*",
      "https://*/*",
      "http://*/*",
    ],
    action: {
      default_icon: {
        "16": "icon-16.png",
        "48": "icon-48.png",
        "128": "icon-128.png",
      },
    },
    icons: {
      "16": "icon-16.png",
      "48": "icon-48.png",
      "128": "icon-128.png",
    },
    web_accessible_resources: [
      {
        resources: [
          "lib/single-file.js",
          "lib/single-file-frames.js",
          "lib/single-file-bootstrap.js",
          "lib/single-file-hooks-frames.js",
        ],
        matches: ["<all_urls>"],
      },
    ],
  },
});
