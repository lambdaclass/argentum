import { buildAssetUrlCandidates } from "../net/assetHost";
import type { SoundEffectPayload } from "../net/SessionClient";

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

    const candidatePaths = [
      ...(payload.localize ? localePrefixes().map((prefix) => `/sounds/${prefix}_${payload.wav}.ogg`) : []),
      `/sounds/${payload.wav}.ogg`
    ];
    const candidates = Array.from(
      new Set(candidatePaths.flatMap((path) => buildAssetUrlCandidates(endpoint, path)))
    );

    if (payload.cancelLast && this.cancellableAudio) {
      this.cancellableAudio.pause();
      this.cancellableAudio.currentTime = 0;
      this.cancellableAudio = null;
    }

    void this.tryPlay(candidates, payload.cancelLast);
  }

  destroy() {
    if (this.cancellableAudio) {
      this.cancellableAudio.pause();
      this.cancellableAudio.currentTime = 0;
      this.cancellableAudio = null;
    }
  }

  private async tryPlay(candidates: string[], trackAsCancellable: boolean) {
    for (const candidate of candidates) {
      const audio = new Audio(candidate);
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
