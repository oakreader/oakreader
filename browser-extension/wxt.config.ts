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
    host_permissions: ["http://localhost:23119/*", "https://*/*", "http://*/*"],
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
