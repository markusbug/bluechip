import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    // contracts/deployments/*.json and contracts/basket/mag7.json live one level up.
    fs: { allow: [".."] },
  },
  build: {
    target: "es2022",
    sourcemap: false,
  },
});
