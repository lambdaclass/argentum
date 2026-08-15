/**
 * Shows which bundle is actually running.
 *
 * A cached bundle after a rebuild looks exactly like a fix that did not work,
 * so any "is it better now?" answer is unreliable until you can see the build
 * you are testing. Click to copy, and `window.__AO_BUILD__` exposes the same
 * string for pasting into a bug report.
 */
export function BuildStamp() {
  const buildId = __AO_BUILD_ID__;

  return (
    <button
      type="button"
      className="build-stamp"
      data-dev={buildId === "dev" ? "true" : undefined}
      data-dirty={buildId.includes("+dirty") ? "true" : undefined}
      title={`Build ${buildId} — click to copy`}
      data-testid="build-stamp"
      onClick={() => {
        void navigator.clipboard?.writeText(buildId);
      }}
    >
      {buildId}
    </button>
  );
}

if (typeof window !== "undefined") {
  (window as unknown as Record<string, unknown>).__AO_BUILD__ = __AO_BUILD_ID__;
}
