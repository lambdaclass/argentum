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
  private enabled = true;
  private volume = 0.85;

  setEnabled(enabled: boolean) {
    this.enabled = enabled;

    if (!enabled && this.cancellableAudio) {
      this.cancellableAudio.pause();
      this.cancellableAudio.currentTime = 0;
      this.cancellableAudio = null;
    }
  }

  setVolume(volume: number) {
    this.volume = Math.max(0, Math.min(1, volume));

    if (this.cancellableAudio) {
      this.cancellableAudio.volume = this.volume;
    }
  }

  playWave(endpoint: string, payload: SoundEffectPayload) {
    if (typeof window === "undefined" || !this.enabled || payload.wav <= 0) {
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
      audio.volume = this.volume;

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
