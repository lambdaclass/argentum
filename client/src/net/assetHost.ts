function isBrowserHttp() {
  return typeof window !== "undefined" && window.location.protocol.startsWith("http");
}

function isLocalDevServer() {
  if (!isBrowserHttp()) {
    return false;
  }

  return window.location.port === "5173" || window.location.port === "4173";
}

function originFromEndpoint(endpoint: string) {
  const url = new URL(endpoint);
  url.protocol = url.protocol === "wss:" ? "https:" : "http:";
  url.pathname = "/";
  url.search = "";
  url.hash = "";
  return url.origin;
}

export function buildAssetOriginCandidates(endpoint: string) {
  const origins: string[] = [];

  if (isBrowserHttp() && !isLocalDevServer()) {
    origins.push(window.location.origin);
  }

  origins.push(originFromEndpoint(endpoint));

  return Array.from(new Set(origins));
}

export function buildAssetUrlFromOrigin(origin: string, path: string) {
  return new URL(path, origin).toString();
}

export function buildAssetUrlCandidates(endpoint: string, path: string) {
  return buildAssetOriginCandidates(endpoint).map((origin) => buildAssetUrlFromOrigin(origin, path));
}

function previewBody(body: string) {
  return body.replace(/\s+/g, " ").slice(0, 80);
}

function parseJson<T>(raw: string, url: string) {
  try {
    return JSON.parse(raw) as T;
  } catch {
    const preview = previewBody(raw);
    const detail = preview.length === 0 ? "empty response" : `unexpected body starting with ${JSON.stringify(preview)}`;
    throw new Error(`Expected JSON at ${url}, got ${detail}`);
  }
}

export async function fetchJsonAtOrigin<T>(origin: string, path: string, init?: RequestInit) {
  const url = buildAssetUrlFromOrigin(origin, path);
  const response = await fetch(url, init);

  if (!response.ok) {
    throw new Error(`Failed to load ${path} (${response.status}) at ${url}`);
  }

  return parseJson<T>(await response.text(), url);
}

export async function fetchJsonWithFallback<T>(endpoint: string, path: string, init?: RequestInit) {
  let lastError: Error | null = null;

  for (const origin of buildAssetOriginCandidates(endpoint)) {
    try {
      const data = await fetchJsonAtOrigin<T>(origin, path, init);
      return { data, origin };
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
    }
  }

  throw lastError ?? new Error(`Failed to load ${path}`);
}
