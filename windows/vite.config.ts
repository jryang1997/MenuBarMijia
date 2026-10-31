import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { defineConfig } from "vite";

const configDir = fileURLToPath(new URL(".", import.meta.url));

// The Windows package version is the repository's VERSION file; injecting it at build
// time lets the update checker compare without a runtime Tauri call (#39).
function appVersion(): string {
  try {
    const version = readFileSync(resolve(configDir, "../VERSION"), "utf8").trim();
    if (version) return version;
  } catch {
    // fall through to package.json
  }
  try {
    const pkg = JSON.parse(readFileSync(resolve(configDir, "package.json"), "utf8")) as { version?: string };
    if (pkg.version) return pkg.version;
  } catch {
    // fall through
  }
  return "0.0.0";
}

export default defineConfig({
  define: {
    __APP_VERSION__: JSON.stringify(appVersion()),
  },
  clearScreen: false,
  server: {
    host: process.env.DISABLE_HMR === "true" ? "0.0.0.0" : undefined,
    port: process.env.PORT ? Number(process.env.PORT) : process.env.DISABLE_HMR === "true" ? 3000 : 1420,
    strictPort: true,
    allowedHosts: true,
    hmr: process.env.DISABLE_HMR === "true" ? false : undefined,
  },
  build: {
    target: "es2022",
    outDir: "dist",
    emptyOutDir: true,
  },
});
