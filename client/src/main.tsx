import React from "react";
import ReactDOM from "react-dom/client";
import { App } from "./app/App";
import { PlaywrightHarness } from "./playwright/PlaywrightHarness";
import "./styles.css";

const isPlaywrightRoute =
  typeof window !== "undefined" && window.location.pathname.startsWith("/playwright");

ReactDOM.createRoot(document.getElementById("app") as HTMLElement).render(
  <React.StrictMode>
    {isPlaywrightRoute ? <PlaywrightHarness /> : <App />}
  </React.StrictMode>
);
