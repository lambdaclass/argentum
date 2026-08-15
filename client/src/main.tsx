import React, { Suspense, lazy } from "react";
import ReactDOM from "react-dom/client";
import { App } from "./app/App";
import { BuildStamp } from "./ui/BuildStamp";
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

function formatFatalError(error: unknown) {
  if (error instanceof ErrorEvent) {
    return formatFatalError(error.error ?? error.message);
  }

  if (error instanceof Error) {
    return {
      summary: error.message,
      detail: error.stack ?? error.message
    };
  }

  if (typeof error === "string") {
    return {
      summary: error,
      detail: error
    };
  }

  try {
    const serialized = JSON.stringify(error);
    return {
      summary: serialized,
      detail: serialized
    };
  } catch {
    return {
      summary: String(error),
      detail: String(error)
    };
  }
}

function isNonFatalBrowserEvent(error: unknown) {
  if (error instanceof Event) {
    return !(error instanceof ErrorEvent);
  }

  if (
    typeof error === "object" &&
    error != null &&
    "isTrusted" in error &&
    !("message" in error) &&
    !("stack" in error)
  ) {
    return true;
  }

  return false;
}

function renderFatalBootScreen(summary: string, detail: string) {
  const mountNode = document.getElementById("app");
  if (!mountNode) {
    return;
  }

  mountNode.innerHTML = `
    <div class="boot-fatal-screen">
      <div class="boot-fatal-card">
        <p class="boot-fatal-eyebrow">Client Boot</p>
        <h1>Fatal Runtime Error</h1>
        <p class="boot-fatal-copy">${summary.replace(/</g, "&lt;")}</p>
        <pre class="boot-fatal-detail">${detail.replace(/</g, "&lt;")}</pre>
      </div>
    </div>
  `;
}

class RootErrorBoundary extends React.Component<
  React.PropsWithChildren,
  { summary: string | null; detail: string | null }
> {
  state = {
    summary: null,
    detail: null
  };

  static getDerivedStateFromError(error: unknown) {
    return formatFatalError(error);
  }

  componentDidCatch(error: unknown) {
    const { summary, detail } = formatFatalError(error);
    console.error("RootErrorBoundary", error);
    renderFatalBootScreen(summary, detail);
  }

  render() {
    if (this.state.summary && this.state.detail) {
      return (
        <div className="boot-fatal-screen">
          <div className="boot-fatal-card">
            <p className="boot-fatal-eyebrow">Client Boot</p>
            <h1>Fatal Runtime Error</h1>
            <p className="boot-fatal-copy">{this.state.summary}</p>
            <pre className="boot-fatal-detail">{this.state.detail}</pre>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

if (typeof window !== "undefined") {
  window.addEventListener("error", (event) => {
    if (isNonFatalBrowserEvent(event)) {
      console.warn("window.error resource event", event);
      return;
    }

    if (!event.error && !event.message) {
      return;
    }

    const fatal = event.error ?? event.message;
    if (isNonFatalBrowserEvent(fatal)) {
      console.warn("window.error non-fatal payload", fatal);
      return;
    }

    const { summary, detail } = formatFatalError(fatal);
    console.error("window.error", fatal);
    renderFatalBootScreen(summary, detail);
  });

  window.addEventListener("unhandledrejection", (event) => {
    if (isNonFatalBrowserEvent(event.reason)) {
      console.warn("window.unhandledrejection non-fatal payload", event.reason);
      return;
    }

    const { summary, detail } = formatFatalError(event.reason);
    console.error("window.unhandledrejection", event.reason);
    renderFatalBootScreen(summary, detail);
  });
}

const mountNode = document.getElementById("app") as HTMLElement;

ReactDOM.createRoot(mountNode).render(
  <React.StrictMode>
    <RootErrorBoundary>
      {isPlaywrightRoute && PlaywrightHarness ? (
        <Suspense fallback={null}>
          <PlaywrightHarness />
        </Suspense>
      ) : (
        <App uiDemoMode={uiDemoMode} />
      )}
    </RootErrorBoundary>
    {/* Outside the error boundary so the build is still identifiable on a
        fatal boot error — that is exactly when you need to know which bundle
        you are looking at. */}
    <BuildStamp />
  </React.StrictMode>
);
