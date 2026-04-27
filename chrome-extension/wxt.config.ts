import { defineConfig } from "wxt";

export default defineConfig({
  manifest: {
    name: "OakReader",
    description: "Save web pages, YouTube videos, and podcasts to OakReader",
    permissions: ["activeTab", "scripting"],
    host_permissions: ["http://localhost:23119/*"],
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
