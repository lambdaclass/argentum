import { execSync } from "node:child_process";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

/**
 * Identify the running bundle in the browser.
 *
 * A stale bundle after a rebuild is indistinguishable from a fix that did not
 * work, which makes every "is it better?" answer unreliable. Stamping the commit
 * and build time into the page removes that ambiguity.
 */
function buildStamp(command: string) {
  if (command !== "build") {
    return "dev";
  }

  let commit = "nogit";
  let dirty = "";

  try {
    commit = execSync("git rev-parse --short HEAD", { stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
    const status = execSync("git status --porcelain", { stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
    dirty = status.length > 0 ? "+dirty" : "";
  } catch {
    // Not a git checkout (release tarball, CI export) — the timestamp still
    // distinguishes builds, so carry on rather than failing the build.
  }

  const builtAt = new Date().toISOString().slice(11, 19);
  return `${commit}${dirty} ${builtAt}`;
}

export default defineConfig(({ command, mode }) => {
  const enableTestSurfaces = mode === "test-ui" || process.env.VITE_ENABLE_TEST_SURFACES === "1";
  const clientBase = command === "build" ? "/client/" : "/";

  return {
    base: clientBase,
    define: {
      __AO_ENABLE_TEST_SURFACES__: JSON.stringify(enableTestSurfaces),
      __AO_BUILD_ID__: JSON.stringify(buildStamp(command))
    },
    plugins: [react()],
    build: {
      rollupOptions: {
        output: {
          manualChunks(id) {
            if (!id.includes("node_modules")) {
              return undefined;
            }

            if (id.includes("pixi.js")) {
              return "pixi";
            }

            return undefined;
          }
        }
      }
    },
    server: {
      host: "127.0.0.1",
      port: 5173,
      proxy: {
        "/api": {
          target: "http://127.0.0.1:7667",
          changeOrigin: true
        }
      }
    },
    preview: {
      host: "127.0.0.1",
      port: 4173
    }
  };
});
