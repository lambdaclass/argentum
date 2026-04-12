import { buildAssetUrlCandidates } from "../net/assetHost";

type SoundfontInstrument = {
  play: (noteName: string, when?: number, options?: { gain?: number }) => void;
};

type MidiPlayerEvent = {
  name: string;
  velocity: number;
  noteName: string;
};

type MidiPlayerInstance = {
  on: (eventName: string, callback: () => void) => void;
  stop: () => void;
  loadArrayBuffer: (buffer: Uint8Array) => void;
  play: () => void;
};

type MidiPlayerCtor = new (callback: (event: MidiPlayerEvent) => void) => MidiPlayerInstance;

declare global {
  interface Window {
    MidiPlayer?: { Player: MidiPlayerCtor };
    Soundfont?: {
      instrument: (context: AudioContext, instrumentName: string) => Promise<SoundfontInstrument>;
    };
    webkitAudioContext?: typeof AudioContext;
  }
}

const MIDI_PLAYER_URL =
  "https://cdn.jsdelivr.net/npm/midi-player-js@2.0.16/browser/midiplayer.min.js";
const SOUNDFONT_PLAYER_URL =
  "https://cdn.jsdelivr.net/npm/soundfont-player@0.12.0/dist/soundfont-player.min.js";
const ENCODED_TRACK_EXTENSIONS = ["ogg", "mp3", "webm"] as const;

const loadedScripts = new Map<string, Promise<void>>();

function loadScript(url: string) {
  if (loadedScripts.has(url)) {
    return loadedScripts.get(url)!;
  }

  const promise = new Promise<void>((resolve, reject) => {
    if (typeof document === "undefined") {
      reject(new Error("Script loading requires a browser environment."));
      return;
    }

    const existing = document.querySelector<HTMLScriptElement>(`script[data-src="${url}"]`);
    if (existing?.dataset.ready === "true") {
      resolve();
      return;
    }

    const script = existing ?? document.createElement("script");
    script.src = url;
    script.async = true;
    script.dataset.src = url;

    script.addEventListener("load", () => {
      script.dataset.ready = "true";
      resolve();
    });

    script.addEventListener("error", () => {
      loadedScripts.delete(url);
      reject(new Error(`Failed to load script ${url}`));
    });

    if (!existing) {
      document.head.appendChild(script);
    }
  });

  loadedScripts.set(url, promise);
  return promise;
}

function isRealAudioResponse(response: Response) {
  const contentType = response.headers.get("content-type")?.toLowerCase() ?? "";
  return !contentType.includes("text/html");
}

function teardownAudioElement(audio: HTMLAudioElement) {
  audio.pause();
  audio.currentTime = 0;
  audio.removeAttribute("src");
  audio.load();
}

export class MapMusicController {
  private context: AudioContext | null = null;
  private instrument: SoundfontInstrument | null = null;
  private player: MidiPlayerInstance | null = null;
  private audioElement: HTMLAudioElement | null = null;
  private initPromise: Promise<void> | null = null;
  private currentMusicId: number | null = null;
  private enabled = true;
  private volume = 0.6;
  private destroyed = false;
  private playRequestId = 0;
  private readonly resumeAudio = () => {
    void this.context?.resume();
  };

  setEnabled(enabled: boolean) {
    this.enabled = enabled;

    if (!enabled) {
      this.stop();
    }
  }

  setVolume(volume: number) {
    this.volume = Math.max(0, Math.min(1, volume));
    if (this.audioElement) {
      this.audioElement.volume = this.volume;
    }
  }

  async ensureReady() {
    if (this.destroyed) {
      return;
    }

    if (this.player && this.instrument && this.context) {
      return;
    }

    if (!this.initPromise) {
      this.initPromise = this.initialize();
    }

    return this.initPromise;
  }

  async playMapMusic(endpoint: string, musicId: number) {
    const requestId = ++this.playRequestId;

    if (!this.enabled || !musicId || musicId <= 0) {
      this.stopPlayback();
      return;
    }

    if (this.currentMusicId === musicId && (this.audioElement || this.player)) {
      return;
    }

    this.stopPlayback();

    const encodedTrackUrl = await this.findEncodedTrackUrl(endpoint, musicId, requestId);
    if (encodedTrackUrl) {
      const audio = new Audio(encodedTrackUrl);
      audio.crossOrigin = "anonymous";
      audio.loop = true;
      audio.preload = "auto";
      audio.volume = this.volume;

      try {
        await audio.play();
        if (this.destroyed || requestId !== this.playRequestId) {
          teardownAudioElement(audio);
          return;
        }

        this.audioElement = audio;
        this.currentMusicId = musicId;
        return;
      } catch {
        teardownAudioElement(audio);
      }
    }

    await this.ensureReady();

    if (this.destroyed || requestId !== this.playRequestId || !this.player) {
      return;
    }

    if (this.currentMusicId === musicId) {
      return;
    }

    let response: Response | null = null;

    for (const url of buildAssetUrlCandidates(endpoint, `/midi/${musicId}.mid`)) {
      const candidate = await fetch(url);
      if (this.destroyed || requestId !== this.playRequestId) {
        return;
      }
      if (candidate.ok) {
        response = candidate;
        break;
      }
    }

    if (!response) {
      throw new Error(`MIDI file not found: ${musicId}.mid`);
    }

    const buffer = new Uint8Array(await response.arrayBuffer());
    if (this.destroyed || requestId !== this.playRequestId || !this.player) {
      return;
    }
    this.currentMusicId = musicId;
    this.player.stop();
    this.player.loadArrayBuffer(buffer);
    this.player.play();
  }

  stop() {
    this.playRequestId += 1;
    this.stopPlayback();
  }

  private stopPlayback() {
    this.currentMusicId = null;
    if (this.audioElement) {
      teardownAudioElement(this.audioElement);
      this.audioElement = null;
    }
    this.player?.stop();
  }

  destroy() {
    this.destroyed = true;
    this.stop();

    if (typeof window !== "undefined") {
      window.removeEventListener("pointerdown", this.resumeAudio);
      window.removeEventListener("keydown", this.resumeAudio);
    }

    if (this.context) {
      void this.context.close().catch(() => undefined);
    }

    this.context = null;
    this.instrument = null;
    this.player = null;
    this.audioElement = null;
    this.initPromise = null;
  }

  private async findEncodedTrackUrl(endpoint: string, musicId: number, requestId: number) {
    for (const extension of ENCODED_TRACK_EXTENSIONS) {
      for (const url of buildAssetUrlCandidates(endpoint, `/audio/musica/${musicId}.${extension}`)) {
        let response: Response;

        try {
          response = await fetch(url, { method: "HEAD" });
        } catch {
          continue;
        }

        if (this.destroyed || requestId !== this.playRequestId) {
          return null;
        }

        if (response.ok && isRealAudioResponse(response)) {
          return url;
        }
      }
    }

    return null;
  }

  private async initialize() {
    await Promise.all([loadScript(MIDI_PLAYER_URL), loadScript(SOUNDFONT_PLAYER_URL)]);

    if (this.destroyed) {
      return;
    }

    const AudioCtor = window.AudioContext ?? window.webkitAudioContext;
    if (!AudioCtor) {
      throw new Error("Web Audio is not available in this browser.");
    }

    if (!window.Soundfont?.instrument || !window.MidiPlayer?.Player) {
      throw new Error("Music runtime failed to initialize.");
    }

    this.context = new AudioCtor();
    this.instrument = await window.Soundfont.instrument(
      this.context,
      "acoustic_grand_piano"
    );

    if (this.destroyed || !this.context) {
      void this.context?.close().catch(() => undefined);
      this.context = null;
      this.instrument = null;
      return;
    }

    const instrument = this.instrument;
    const context = this.context;

    this.player = new window.MidiPlayer.Player((event: MidiPlayerEvent) => {
      if (!this.enabled) {
        return;
      }

      if (event.name === "Note on" && event.velocity > 0) {
        instrument.play(event.noteName, context.currentTime, {
          gain: (event.velocity / 127) * this.volume
        });
      }
    });

    this.player.on("endOfFile", () => {
      if (this.currentMusicId) {
        this.player?.play();
      }
    });

    window.addEventListener("pointerdown", this.resumeAudio, { passive: true });
    window.addEventListener("keydown", this.resumeAudio);

    if (context.state === "suspended") {
      void context.resume();
    }
  }
}
