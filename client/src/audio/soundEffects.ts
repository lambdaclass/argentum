import type { SoundEffectPayload } from "../net/SessionClient";

function buildAssetUrl(endpoint: string, path: string) {
  if (
    typeof window !== "undefined" &&
    window.location.protocol.startsWith("http") &&
    window.location.port !== "5173" &&
    window.location.port !== "4173"
  ) {
    return new URL(path, window.location.origin).toString();
  }

  const url = new URL(endpoint);
  url.protocol = url.protocol === "wss:" ? "https:" : "http:";
  url.pathname = path;
  url.search = "";
  url.hash = "";
  return url.toString();
}

function localePrefixes() {
  if (typeof navigator === "undefined") {
    return [];
  }

  const languages = navigator.languages?.length ? navigator.languages : [navigator.language];
  return Array.from(
    new Set(
      languages
        .map((entry) => entry?.split("-")[0]?.toLowerCase())
        .filter((entry): entry is string => Boolean(entry))
    )
  );
}

export class SoundEffectsController {
  private cancellableAudio: HTMLAudioElement | null = null;

  playWave(endpoint: string, payload: SoundEffectPayload) {
    if (typeof window === "undefined" || payload.wav <= 0) {
      return;
    }

    const candidates = [
      ...(payload.localize ? localePrefixes().map((prefix) => `/sounds/${prefix}_${payload.wav}.ogg`) : []),
      `/sounds/${payload.wav}.ogg`
    ];

    if (payload.cancelLast && this.cancellableAudio) {
      this.cancellableAudio.pause();
      this.cancellableAudio.currentTime = 0;
      this.cancellableAudio = null;
    }

    void this.tryPlay(endpoint, candidates, payload.cancelLast);
  }

  destroy() {
    if (this.cancellableAudio) {
      this.cancellableAudio.pause();
      this.cancellableAudio.currentTime = 0;
      this.cancellableAudio = null;
    }
  }

  private async tryPlay(endpoint: string, candidates: string[], trackAsCancellable: boolean) {
    for (const candidate of candidates) {
      const audio = new Audio(buildAssetUrl(endpoint, candidate));
      audio.preload = "auto";
      audio.volume = 0.85;

      try {
        await audio.play();
        if (trackAsCancellable) {
          this.cancellableAudio = audio;
        }
        return;
      } catch {
        audio.pause();
      }
    }
  }
}
