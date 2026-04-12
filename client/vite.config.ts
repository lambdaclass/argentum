import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ command, mode }) => {
  const enableTestSurfaces = mode === "test-ui" || process.env.VITE_ENABLE_TEST_SURFACES === "1";
  const clientBase = command === "build" ? "/client/" : "/";

  return {
    base: clientBase,
    define: {
      __AO_ENABLE_TEST_SURFACES__: JSON.stringify(enableTestSurfaces)
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
