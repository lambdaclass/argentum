import type { ConnectionStatus, ClientState } from "./types";

export type LoadStatus = "idle" | "loading" | "ready" | "error";
export type SceneBootstrapStatus = "idle" | "loading" | "ready" | "error";
export type ViewportNoticeTone = "connecting" | "loading" | "error" | "reconnect" | "warning" | "danger";

export interface ViewportNotice {
  eyebrow: string;
  title: string;
  copy: string;
  tone: ViewportNoticeTone;
}

export interface SceneBootstrapGateInput {
  isGameplayRoute: boolean;
  assetStatus: LoadStatus;
  mapPackStatus: LoadStatus;
  connectionStatus: ConnectionStatus;
  mapStatus: ClientState["world"]["mapStatus"];
  hasMap: boolean;
  hasAssetCatalog: boolean;
  hasSelfCharIndex: boolean;
  hasSelfPosition: boolean;
}

export interface ViewportNoticeInput {
  assetStatus: LoadStatus;
  mapPackStatus: LoadStatus;
  connectionStatus: ConnectionStatus;
  hasSavedSession: boolean;
  connectionError: string | null;
  mapStatus: ClientState["world"]["mapStatus"];
  mapError: string | null;
  hasMap: boolean;
  sceneBootstrapStatus: SceneBootstrapStatus;
  sceneBootstrapError: string | null;
}

export function describeConnectionIssue(
  error: string | null,
  hasSavedSession: boolean
): ViewportNotice | null {
  if (!error) {
    return null;
  }

  const normalized = error.toLowerCase();

  if (normalized.includes("banned")) {
    return {
      eyebrow: "Access",
      title: "Account banned",
      copy: "This account is blocked on the client side until the backend or an admin clears the ban.",
      tone: "danger"
    };
  }

  if (normalized.includes("muted")) {
    return {
      eyebrow: "Access",
      title: "Chat muted",
      copy: "The account can still exist, but chat actions are restricted until the mute is cleared.",
      tone: "warning"
    };
  }

  if (normalized.includes("server full") || normalized.includes("server-full") || normalized.includes("full")) {
    return {
      eyebrow: "Access",
      title: "Server full",
      copy: "The world reached its capacity limit. Retry once a slot opens up.",
      tone: "warning"
    };
  }

  if (normalized.includes("maintenance")) {
    return {
      eyebrow: "Access",
      title: "Maintenance mode",
      copy: "The world is offline for maintenance. Try again when the server comes back.",
      tone: "warning"
    };
  }

  if (normalized.includes("token expired")) {
    return {
      eyebrow: "Access",
      title: "Session expired",
      copy: hasSavedSession
        ? "The saved reconnect token expired. Sign in again to get a fresh session."
        : "Your session expired. Sign in again to get a fresh token.",
      tone: "danger"
    };
  }

  return null;
}

export function canStartInitialSceneBootstrap(input: SceneBootstrapGateInput) {
  return (
    input.isGameplayRoute &&
    input.assetStatus === "ready" &&
    input.mapPackStatus === "ready" &&
    input.connectionStatus === "connected" &&
    input.mapStatus === "ready" &&
    input.hasMap &&
    input.hasAssetCatalog &&
    input.hasSelfCharIndex &&
    input.hasSelfPosition
  );
}

export function describeViewportNotice(input: ViewportNoticeInput): ViewportNotice | null {
  if (input.assetStatus !== "ready" || input.mapPackStatus !== "ready") {
    return null;
  }

  if (input.connectionStatus === "connecting") {
    return {
      eyebrow: "Cuenta",
      title: input.hasSavedSession ? "Reconnecting" : "Connecting",
      copy: input.hasSavedSession
        ? "Reusing the saved session to reconnect this account."
        : "Opening the account login flow with the current name and password.",
      tone: "connecting"
    };
  }

  if (input.mapStatus === "error") {
    return {
      eyebrow: "Map",
      title: "Map Load Failed",
      copy: input.mapError ?? "The world data could not be loaded.",
      tone: "error"
    };
  }

  if ((input.mapStatus === "loading" || input.mapStatus === "transferring") && !input.hasMap) {
    return {
      eyebrow: "Map",
      title: input.mapStatus === "transferring" ? "Changing Map" : "Loading Map",
      copy: "Keeping the session alive while the destination map is prepared.",
      tone: "loading"
    };
  }

  if (input.sceneBootstrapStatus === "loading") {
    return {
      eyebrow: "Map",
      title: "Preparing Scene",
      copy: "Loading the current map art and actor sheets before entering the world.",
      tone: "loading"
    };
  }

  if (input.sceneBootstrapStatus === "error") {
    return {
      eyebrow: "Map",
      title: "Scene Load Failed",
      copy: input.sceneBootstrapError ?? "The first map scene could not be prepared.",
      tone: "error"
    };
  }

  if (input.connectionStatus === "offline" && !input.hasMap) {
    const issue = describeConnectionIssue(input.connectionError, input.hasSavedSession);
    if (issue) {
      return issue;
    }

    return {
      eyebrow: "Cuenta",
      title: input.hasSavedSession ? "Reconnect Ready" : "Ready To Enter",
      copy:
        input.connectionError ??
        (input.hasSavedSession
          ? "Assets are loaded. A saved reconnect session is ready in Sesion."
          : "Assets are loaded. Enter an account name and password in Sesion, then connect."),
      tone: "reconnect"
    };
  }

  return null;
}
