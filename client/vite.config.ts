import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => {
  const enableTestSurfaces = mode === "test-ui" || process.env.VITE_ENABLE_TEST_SURFACES === "1";

  return {
    base: "/",
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
      port: 5173
    },
    preview: {
      host: "127.0.0.1",
      port: 4173
    }
  };
});
