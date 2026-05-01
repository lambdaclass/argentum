export interface BrowserAccount {
  id: number;
  username: string;
}

export interface BrowserSessionPayload {
  authenticated: boolean;
  account: BrowserAccount | null;
}

export interface BrowserCharacter {
  id: number;
  name: string;
  level: number;
  xp: number;
  class: string;
  class_label: string;
  race: string;
  race_label: string;
  gender: string;
  gender_label: string;
  home_city: string;
  home_city_label: string;
  map_id: number;
  pos_x: number;
  pos_y: number;
  dead: boolean;
  criminal: boolean;
  gold: number;
  body_id: number;
  head_id: number;
  helmet_id: number | null;
  weapon_id: number | null;
  shield_id: number | null;
  online: boolean;
}

export interface CharacterOption {
  id: number;
  label: string;
}

export interface CharacterHeadRange {
  min: number;
  max: number;
}

export interface CharacterCreationOptions {
  races: CharacterOption[];
  genders: CharacterOption[];
  classes: CharacterOption[];
  home_cities: CharacterOption[];
  head_ranges: Record<string, CharacterHeadRange[]>;
  body_ids: Record<string, number>;
  defaults: {
    race: number;
    gender: number;
    class: number;
    home_city: number;
    head: number;
  };
}

export interface BrowserRankingEntry {
  rank: number;
  character: BrowserCharacter & {
    kills: number;
  };
}

export interface LaunchCharacterPayload {
  character: BrowserCharacter;
  credentials: {
    char_id: number;
    token: string;
  };
}

export interface ProductApiClient {
  fetchBrowserSession: typeof fetchBrowserSession;
  loginBrowserAccount: typeof loginBrowserAccount;
  registerBrowserAccount: typeof registerBrowserAccount;
  logoutBrowserAccount: typeof logoutBrowserAccount;
  fetchCharacterOptions: typeof fetchCharacterOptions;
  fetchBrowserCharacters: typeof fetchBrowserCharacters;
  createBrowserCharacter: typeof createBrowserCharacter;
  launchBrowserCharacter: typeof launchBrowserCharacter;
  fetchBrowserRanking: typeof fetchBrowserRanking;
}

interface ApiErrorPayload {
  error?: boolean;
  message?: string;
}

function describeUnexpectedApiBody(path: string, response: Response) {
  if (path.startsWith("/api/auth/")) {
    return "The browser auth API is not available on this server yet. Refresh after the web server reloads.";
  }

  return `Expected JSON from ${path}, but received ${response.headers.get("content-type") ?? "an unexpected response"}.`;
}

async function requestJson<T>(path: string, init?: RequestInit) {
  const response = await fetch(path, {
    credentials: "include",
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {})
    },
    ...init
  });

  const text = await response.text();
  let data: T | ApiErrorPayload | null = null;

  if (text.length > 0) {
    try {
      data = JSON.parse(text) as T | ApiErrorPayload;
    } catch {
      throw new Error(describeUnexpectedApiBody(path, response));
    }
  }

  if (!response.ok) {
    const message =
      data && typeof data === "object" && "message" in data && typeof data.message === "string"
        ? data.message
        : `Request failed with status ${response.status}.`;
    throw new Error(message);
  }

  return data as T;
}

export function fetchBrowserSession() {
  return requestJson<BrowserSessionPayload>("/api/auth/session");
}

export function loginBrowserAccount(username: string, password: string) {
  return requestJson<{ account: BrowserAccount }>("/api/auth/login", {
    method: "POST",
    body: JSON.stringify({ username, password })
  });
}

export function registerBrowserAccount(username: string, password: string) {
  return requestJson<{ account: BrowserAccount }>("/api/auth/register", {
    method: "POST",
    body: JSON.stringify({ username, password })
  });
}

export function logoutBrowserAccount() {
  return requestJson<{ logout: boolean }>("/api/auth/logout", {
    method: "POST",
    body: JSON.stringify({})
  });
}

export function fetchCharacterOptions() {
  return requestJson<CharacterCreationOptions>("/api/meta/character-options");
}

export function fetchBrowserCharacters() {
  return requestJson<{ characters: BrowserCharacter[] }>("/api/characters");
}

export function createBrowserCharacter(payload: {
  name: string;
  race: number;
  gender: number;
  class: number;
  head: number;
  home_city: number;
}) {
  return requestJson<{ character: BrowserCharacter }>("/api/characters", {
    method: "POST",
    body: JSON.stringify(payload)
  });
}

export function launchBrowserCharacter(characterId: number) {
  return requestJson<LaunchCharacterPayload>(`/api/characters/${characterId}/session`, {
    method: "POST",
    body: JSON.stringify({})
  });
}

export function fetchBrowserRanking(limit = 50) {
  return requestJson<{ entries: BrowserRankingEntry[] }>(`/api/ranking/general?limit=${limit}`);
}

export const browserProductApi: ProductApiClient = {
  fetchBrowserSession,
  loginBrowserAccount,
  registerBrowserAccount,
  logoutBrowserAccount,
  fetchCharacterOptions,
  fetchBrowserCharacters,
  createBrowserCharacter,
  launchBrowserCharacter,
  fetchBrowserRanking
};
