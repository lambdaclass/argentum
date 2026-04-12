import React, { Suspense, lazy } from "react";
import ReactDOM from "react-dom/client";
import { App } from "./app/App";
import "./styles.css";

const PlaywrightHarness = lazy(async () => {
  const module = await import("./playwright/PlaywrightHarness");
  return { default: module.PlaywrightHarness };
});

const isPlaywrightRoute =
  typeof window !== "undefined" && window.location.pathname.startsWith("/playwright");

ReactDOM.createRoot(document.getElementById("app") as HTMLElement).render(
  <React.StrictMode>
    {isPlaywrightRoute ? (
      <Suspense fallback={null}>
        <PlaywrightHarness />
      </Suspense>
    ) : (
      <App />
    )}
  </React.StrictMode>
);
