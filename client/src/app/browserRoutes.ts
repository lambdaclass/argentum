export type BrowserRoute = "/" | "/ranking" | "/create-character" | "/play";

export function browserBasePath(pathname: string) {
  return pathname === "/client" || pathname.startsWith("/client/") ? "/client" : "";
}

export function normalizeBrowserRoute(pathname: string): BrowserRoute {
  const base = browserBasePath(pathname);
  const stripped = normalizePath(base ? pathname.slice(base.length) : pathname);

  switch (stripped) {
    case "/":
    case "/ranking":
    case "/create-character":
    case "/play":
      return stripped;
    default:
      return "/";
  }
}

export function buildBrowserPath(route: BrowserRoute, currentPathname: string) {
  const base = browserBasePath(currentPathname);

  if (route === "/") {
    return base || "/";
  }

  return `${base}${route}`;
}

function normalizePath(pathname: string) {
  if (pathname === "" || pathname === "/") {
    return "/";
  }

  return pathname.endsWith("/") ? pathname.slice(0, -1) || "/" : pathname;
}
