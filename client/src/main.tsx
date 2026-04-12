import React, { Suspense, lazy } from "react";
import ReactDOM from "react-dom/client";
import { App } from "./app/App";
import "./styles.css";

const PlaywrightHarness = __AO_ENABLE_TEST_SURFACES__
  ? lazy(async () => {
      const module = await import("./playwright/PlaywrightHarness");
      return { default: module.PlaywrightHarness };
    })
  : null;

const isPlaywrightRoute =
  __AO_ENABLE_TEST_SURFACES__ &&
  typeof window !== "undefined" &&
  window.location.pathname.startsWith("/playwright");

const uiDemoMode =
  __AO_ENABLE_TEST_SURFACES__ &&
  typeof window !== "undefined" &&
  new URLSearchParams(window.location.search).get("demo") === "1";

ReactDOM.createRoot(document.getElementById("app") as HTMLElement).render(
  <React.StrictMode>
    {isPlaywrightRoute && PlaywrightHarness ? (
      <Suspense fallback={null}>
        <PlaywrightHarness />
      </Suspense>
    ) : (
      <App uiDemoMode={uiDemoMode} />
    )}
  </React.StrictMode>
);
