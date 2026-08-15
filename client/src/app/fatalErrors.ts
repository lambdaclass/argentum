/**
 * Classifying browser error reports before they are treated as fatal.
 *
 * The boot screen replaces the mount node's innerHTML, so misclassifying a
 * benign report ends the player's session. These predicates are pure so they
 * can be tested without a DOM.
 */

/** The subset of ErrorEvent these predicates need. */
export interface ErrorEventLike {
  error?: unknown;
  message?: string;
  filename?: string;
  lineno?: number;
  colno?: number;
}

/**
 * The browser's opaque cross-origin error report.
 *
 * When a script or media resource from another origin throws, the browser
 * withholds everything: `message` is "Script error.", `error` is null, there is
 * no filename and the position is 0:0. It says nothing about our code, and this
 * client provokes it routinely by probing audio on the gateway origin, which is
 * a different origin from the page.
 *
 * Left unfiltered it reached renderFatalBootScreen and tore down a live session.
 */
export function isOpaqueCrossOriginError(event: ErrorEventLike): boolean {
  return (
    event.error == null &&
    (event.lineno ?? 0) === 0 &&
    (event.colno ?? 0) === 0 &&
    !event.filename
  );
}

/**
 * Resource-load failures and other non-Error events.
 *
 * An `error` event from a failed <img>/<audio> load is a plain Event, not an
 * ErrorEvent, and carries no diagnostic payload.
 */
export function isNonFatalBrowserPayload(error: unknown): boolean {
  if (typeof Event !== "undefined" && error instanceof Event) {
    return !(typeof ErrorEvent !== "undefined" && error instanceof ErrorEvent);
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
