import { defineConfig } from "wxt";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  modules: ["@wxt-dev/module-react"],
  vite: () => ({
    plugins: [tailwindcss()],
  }),
  manifest: {
    name: "OakReader",
    description: "Save web pages, YouTube videos, and podcasts to OakReader",
    permissions: ["activeTab", "scripting", "tabs", "webRequest", "cookies"],
    host_permissions: ["http://localhost:23119/*", "https://*/*", "http://*/*"],
    content_scripts: [
      {
        matches: ["<all_urls>"],
        js: ["page-hooks.js"],
        run_at: "document_start",
        world: "MAIN",
      },
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
  },
});
