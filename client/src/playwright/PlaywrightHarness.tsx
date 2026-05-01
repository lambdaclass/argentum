import { Suspense, lazy, useMemo, useState, type ReactNode } from "react";
import { createInitialState } from "../app/appReducer";
import type { BrowserRoute } from "../app/browserRoutes";
import { applyKeyBinding, createDefaultSettings } from "../app/settings";
import type {
  ClientState,
  InventorySlot,
  SpellSlot,
  TradeOfferSlot,
  WorldMapData
} from "../app/types";
import { getSpellMetadata } from "../data/gameData";
import { SessionClient } from "../net/SessionClient";
import { WorldCanvas } from "../render/WorldCanvas";
import type { AssetCatalog } from "../render/assetCatalog";
import type {
  BrowserAccount,
  BrowserCharacter,
  BrowserRankingEntry,
  CharacterCreationOptions,
  ProductApiClient
} from "../product/api";
import { WorldStatusPanel } from "../ui/WorldStatusPanel";
import { ClansPanel } from "../ui/ClansPanel";
import { HechizosPanel } from "../ui/HechizosPanel";
import { PartyPanel } from "../ui/PartyPanel";
import { ProductShell } from "../ui/ProductShell";
import { SessionPanel } from "../ui/SessionPanel";
import { TradePanel } from "../ui/TradePanel";
const SpritePreviewPage = lazy(async () => {
  const module = await import("./spriteRegressionGallery");
  return { default: module.SpritePreviewPage };
});

function spellSlot(spellId: number): SpellSlot {
  return {
    spellId,
    name: getSpellMetadata(spellId)?.name ?? `Spell ${spellId}`
  };
}

function inventorySlot(itemId: number, amount: number, equipped = false): InventorySlot {
  return {
    itemId,
    amount,
    equipped,
    value: amount * 10,
    canUse: 1
  };
}

function tradeOfferSlot(itemId: number, amount: number): TradeOfferSlot {
  return {
    itemId,
    amount,
    name: `#${itemId}`,
    grhIndex: 0,
    elementalTags: 0
  };
}

function createHarnessMap(): WorldMapData {
  const width = 4;
  const height = 4;
  const tiles = new Uint8Array(width * height);
  tiles[5] = 2;
  const layers = Array.from({ length: 5 }, () => []) as WorldMapData["layers"];

  return {
    mapId: 47,
    name: "Playwright Harbor",
    width,
    height,
    tiles,
    musicHi: 0,
    musicLow: 0,
    layers,
    npcs: [{ x: 2, y: 2, id: 801 }],
    exits: [{ x: 4, y: 4, destMap: 48, destX: 1, destY: 1 }]
  };
}

function cloneInitialState(): ClientState {
  return createInitialState();
}

function createActiveClanState(base: ClientState["clan"]) {
  return {
    ...base,
    open: true,
    name: "Cronistas",
    members: ["PlaywrightHero", "Aster", "Marea"],
    onlineMembers: ["PlaywrightHero", "Aster"],
    rank: "Lider",
    leaderName: "PlaywrightHero",
    founderName: "PlaywrightHero",
    alignment: "Ciudadano",
    description: "Clan de prueba para las pantallas sociales.",
    news: "La cronica de hoy ya esta disponible.",
    memberCount: 3,
    level: 2,
    currentExp: 18,
    neededExp: 30,
    pendingRequests: ["Rhea"]
  };
}

function HarnessShell({
  title,
  description,
  children
}: {
  title: string;
  description: string;
  children: ReactNode;
}) {
  const links = useMemo(
    () => [
      { href: "/playwright", label: "Home" },
      { href: "/playwright/session", label: "Session + spellbook" },
      { href: "/playwright/trade", label: "Trade" },
      { href: "/playwright/social", label: "Social" },
      { href: "/playwright/product", label: "Product" },
      { href: "/playwright/weather", label: "Weather" },
      { href: "/playwright/sprites", label: "Sprites" }
    ],
    []
  );

  return (
    <div style={{ padding: "1.5rem", display: "grid", gap: "1.25rem" }}>
      <header className="panel">
        <p className="eyebrow">Playwright</p>
        <h1>{title}</h1>
        <p className="panel-copy compact">{description}</p>
        <nav
          aria-label="Playwright smoke navigation"
          style={{ display: "flex", flexWrap: "wrap", gap: "0.75rem", marginTop: "1rem" }}
        >
          {links.map((link) => (
            <a className="ghost-button" href={link.href} key={link.href}>
              {link.label}
            </a>
          ))}
        </nav>
      </header>

      {children}
    </div>
  );
}

function SmokeTranscript({
  title,
  entries
}: {
  title: string;
  entries: string[];
}) {
  const slug = title.toLowerCase().replace(/\s+/g, "-").replace(/-transcript$/, "");

  return (
    <section className="panel" data-testid={`${slug}-transcript`}>
      <div className="panel-header">
        <div>
          <p className="eyebrow">Smoke</p>
          <h2>{title}</h2>
        </div>
        <span className="panel-tag">{entries.length}</span>
      </div>

      <ol className="playwright-transcript-list">
        {entries.map((entry, index) => (
          <li key={`${index}-${entry}`}>{entry}</li>
        ))}
      </ol>
    </section>
  );
}

function PlaywrightLanding() {
  return (
    <HarnessShell
      description="Browser-only smoke routes built from the real React panels. No gateway required."
      title="Browser smoke harness"
    >
      <section className="panel">
        <div className="panel-header">
          <div>
            <p className="eyebrow">Routes</p>
            <h2>Quick entry points</h2>
          </div>
          <span className="panel-tag">frontend only</span>
        </div>
          <div className="playwright-launch-grid">
          <a className="ghost-button" href="/playwright/session">
            Session + spellbook
          </a>
          <a className="ghost-button" href="/playwright/trade">
            Trade
          </a>
          <a className="ghost-button" href="/playwright/social">
            Social
          </a>
          <a className="ghost-button" href="/playwright/product">
            Product
          </a>
          <a className="ghost-button" href="/playwright/weather">
            Weather
          </a>
          <a className="ghost-button" href="/playwright/sprites">
            Sprites
          </a>
        </div>
      </section>
    </HarnessShell>
  );
}

function createWeatherState(): ClientState {
  const next = cloneInitialState();
  next.connection.characterName = "PlaywrightWeather";
  next.world.map = createHarnessMap();
  next.world.mapId = next.world.map.mapId;
  next.world.mapStatus = "ready";
  next.world.self.charIndex = 1;
  next.world.self.name = "PlaywrightWeather";
  next.world.self.x = 2;
  next.world.self.y = 2;
  next.weather.raining = true;
  next.weather.snowing = true;
  return next;
}

function WeatherSmokePage() {
  const [state, setState] = useState<ClientState>(() => createWeatherState());
  const session = useMemo(
    () =>
      new SessionClient(
        () => {},
        () => state
      ),
    []
  );

  return (
    <HarnessShell
      description="Weather smoke route with the real world canvas and global weather flags."
      title="Weather smoke"
    >
      <section className="panel" data-testid="playwright-weather-summary">
        <div className="panel-header">
          <div>
            <p className="eyebrow">Status</p>
            <h2>World weather</h2>
          </div>
          <span className="panel-tag">frontend only</span>
        </div>
        <div className="merchant-action-row" style={{ marginTop: "0.75rem" }}>
          <button
            className="ghost-button"
            onClick={() =>
              setState((current) => ({
                ...current,
                weather: { ...current.weather, raining: !current.weather.raining }
              }))
            }
            type="button"
          >
            Toggle rain
          </button>
          <button
            className="ghost-button"
            onClick={() =>
              setState((current) => ({
                ...current,
                weather: { ...current.weather, snowing: !current.weather.snowing }
              }))
            }
            type="button"
          >
            Toggle snow
          </button>
        </div>
      </section>

      <WorldStatusPanel stats={state.stats} weather={state.weather} world={state.world} />

      <section className="panel">
        <div style={{ height: "420px" }}>
          <WorldCanvas
            assetCatalog={null}
            raining={state.weather.raining}
            session={session}
            showTileDebug={false}
            snowing={state.weather.snowing}
            world={state.world}
          />
        </div>
      </section>
    </HarnessShell>
  );
}

function SessionSpellbookSmoke() {
  const [state, setState] = useState<ClientState>(() => {
    const next = cloneInitialState();
    next.connection.characterName = "PlaywrightMage";
    next.connection.bootstrapPassword = "spell smoke";
    next.world.map = createHarnessMap();
    next.world.mapId = next.world.map.mapId;
    next.world.mapStatus = "ready";
    next.world.targetTile = { x: 2, y: 2 };
    next.spellbook.slots[0] = spellSlot(1);
    next.spellbook.slots[1] = spellSlot(2);
    next.spellbook.slots[2] = spellSlot(3);
    next.spellbook.selectedSlot = null;
    return next;
  });
  const [spellHotkeys, setSpellHotkeys] = useState<Array<number | null>>(
    Array.from({ length: 10 }, () => null)
  );
  const [lastCast, setLastCast] = useState("No spell cast yet.");
  const [transcript, setTranscript] = useState<string[]>(["Session smoke route ready."]);

  const connected = state.connection.status === "connected";

  function pushTranscript(entry: string) {
    setTranscript((current) => [entry, ...current].slice(0, 8));
  }

  return (
    <HarnessShell
      description="Connect, inspect the live spellbook, bind a macro, and launch a spell."
      title="Session + spellbook smoke"
    >
      <section className="panel" data-testid="playwright-session-summary">
        <div className="panel-header">
          <div>
            <p className="eyebrow">Status</p>
            <h2>Browser session</h2>
          </div>
          <span className="panel-tag" data-testid="playwright-connection-state">
            {connected ? "connected" : "offline"}
          </span>
        </div>
        <div className="session-status-grid">
          <div className="session-status-card">
            <span>World</span>
            <strong>{state.connection.status === "connected" ? "Playwright Harbor" : state.world.mapStatus}</strong>
          </div>
          <div className="session-status-card">
            <span>Character</span>
            <strong>{state.connection.characterName}</strong>
          </div>
          <div className="session-status-card">
            <span>Last cast</span>
            <strong data-testid="playwright-last-cast">{lastCast}</strong>
          </div>
        </div>
      </section>

      <SessionPanel
        assetError={null}
        assetStatus="ready"
        canConnect
        connection={state.connection}
        mapPackError={null}
        mapPackProgressLabel="World data ready"
        mapPackStatus="ready"
        settings={state.settings}
        showTileDebug={false}
        title="Playwright Harbor"
        world={state.world}
        onBootstrapPasswordChange={(bootstrapPassword) =>
          setState((current) => ({
            ...current,
            connection: { ...current.connection, bootstrapPassword }
          }))
        }
        onCharacterNameChange={(characterName) =>
          setState((current) => ({
            ...current,
            connection: { ...current.connection, characterName }
          }))
        }
        onConnect={() => {
          setState((current) => ({
            ...current,
            connection: {
              ...current.connection,
              status: "connected",
              credentials: { charId: 4701, token: "playwright-token" },
              lastError: null
            },
            world: { ...current.world, mapStatus: "ready" }
          }));
          pushTranscript(`Connected as ${state.connection.characterName}`);
        }}
        onDisconnect={() => {
          setState((current) => ({
            ...current,
            connection: { ...current.connection, status: "offline" }
          }));
          pushTranscript("Disconnected from the session smoke route");
        }}
        onEndpointChange={(endpoint) =>
          setState((current) => ({
            ...current,
            connection: { ...current.connection, endpoint }
          }))
        }
        onForgetSession={() => {
          setState((current) => ({
            ...current,
            connection: {
              ...current.connection,
              status: "offline",
              credentials: null
            }
          }));
          pushTranscript("Forgot the stored reconnect session");
        }}
        onReloadPage={() => {
          pushTranscript("Reload page requested");
        }}
        onResetKeyBindings={() => {
          setState((current) => ({
            ...current,
            settings: {
              ...current.settings,
              controls: createDefaultSettings().controls
            }
          }));
          pushTranscript("Restored default utility bindings");
        }}
        onResetRuntime={() => {
          const next = cloneInitialState();
          setState((current) => ({
            ...next,
            connection: {
              ...next.connection,
              endpoint: current.connection.endpoint,
              characterName: current.connection.characterName,
              bootstrapPassword: current.connection.bootstrapPassword,
              credentials: current.connection.credentials
            },
            settings: current.settings
          }));
          pushTranscript("Reset runtime state");
        }}
        onRetryAssets={() => {
          pushTranscript("Retried asset bootstrap");
        }}
        onRetryBootstrap={() => {
          pushTranscript("Retried full bootstrap");
        }}
        onRetryMapPack={() => {
          pushTranscript("Retried map pack bootstrap");
        }}
        onSetKeyBinding={(action, key) => {
          setState((current) => ({
            ...current,
            settings: {
              ...current.settings,
              controls: {
                ...current.settings.controls,
                bindings: applyKeyBinding(current.settings.controls.bindings, action, key)
              }
            }
          }));
          pushTranscript(`${action} binding changed to ${key ?? "unbound"}`);
        }}
        onSetMusicEnabled={(enabled) =>
          setState((current) => ({
            ...current,
            settings: {
              ...current.settings,
              audio: { ...current.settings.audio, musicEnabled: enabled }
            }
          }))
        }
        onSetMusicVolume={(volume) =>
          setState((current) => ({
            ...current,
            settings: {
              ...current.settings,
              audio: { ...current.settings.audio, musicVolume: volume }
            }
          }))
        }
        onSetSoundEnabled={(enabled) =>
          setState((current) => ({
            ...current,
            settings: {
              ...current.settings,
              audio: { ...current.settings.audio, soundEnabled: enabled }
            }
          }))
        }
        onSetSoundVolume={(volume) =>
          setState((current) => ({
            ...current,
            settings: {
              ...current.settings,
              audio: { ...current.settings.audio, soundVolume: volume }
            }
          }))
        }
      />

      <HechizosPanel
        connected={connected}
        spellHotkeys={spellHotkeys}
        state={state}
        onBindHotkey={(hotkeyIndex, slotIndex) => {
          setSpellHotkeys((current) => {
            const next = [...current];
            next[hotkeyIndex] = slotIndex;
            return next;
          });
          pushTranscript(
            slotIndex == null
              ? `Cleared hotkey ${hotkeyIndex + 1}`
              : `Bound hotkey ${hotkeyIndex + 1} to slot ${slotIndex + 1}`
          );
        }}
        onCast={(slotIndex) => {
          const spell = state.spellbook.slots[slotIndex];
          if (!spell) {
            return;
          }

          setLastCast(`Cast ${spell.name} from slot ${slotIndex + 1}`);
          pushTranscript(`Cast ${spell.name}`);
        }}
        onSelectSlot={(slotIndex) =>
          setState((current) => ({
            ...current,
            spellbook: { ...current.spellbook, selectedSlot: slotIndex }
          }))
        }
      />

      <SmokeTranscript entries={transcript} title="Session transcript" />
    </HarnessShell>
  );
}

function createTradeState(): ClientState {
  const next = cloneInitialState();
  next.connection.characterName = "PlaywrightTrader";
  next.inventory.slots = [
    inventorySlot(101, 6, false),
    inventorySlot(202, 3, false),
    inventorySlot(303, 1, false),
    ...Array.from({ length: 21 }, () => null)
  ];
  next.trade.open = true;
  next.trade.offerAmount = 2;
  next.trade.myOffer.items = Array.from({ length: 10 }, () => null);
  next.trade.otherOffer.items = Array.from({ length: 10 }, () => null);
  return next;
}

function TradeSmokePage() {
  const [state, setState] = useState<ClientState>(() => createTradeState());
  const [transcript, setTranscript] = useState<string[]>(["Trade smoke route ready."]);

  return (
    <HarnessShell description="Offer, accept, and close a trade without the backend." title="Trade smoke">
      <section className="panel" data-testid="playwright-trade-summary">
        <div className="panel-header">
          <div>
            <p className="eyebrow">State</p>
            <h2>Trade status</h2>
          </div>
          <span className="panel-tag">
            {state.trade.accepted ? "accepted" : "editing"}
          </span>
        </div>
        <p className="panel-copy compact">
          Selected slot:{" "}
          {state.inventory.selectedSlot == null ? "none" : `#${state.inventory.selectedSlot + 1}`}
        </p>
      </section>

      <TradePanel
        assetCatalog={null}
        state={state}
        onAccept={() => {
          setState((current) => ({
            ...current,
            trade: {
              ...current.trade,
              accepted: true,
              partnerAccepted: false
            }
          }));
          setTranscript((current) => ["Accepted the local offer", ...current]);
        }}
        onClose={() => {
          setTranscript((current) => ["Closed the trade panel", ...current]);
        }}
        onOffer={(itemId, amount) => {
          setState((current) => {
            const items = [...current.trade.myOffer.items];
            const slotIndex = items.findIndex((slot) => slot == null);
            if (slotIndex !== -1) {
              items[slotIndex] = tradeOfferSlot(itemId, amount);
            }

            return {
              ...current,
              trade: {
                ...current.trade,
                myOffer: {
                  ...current.trade.myOffer,
                  items
                },
                accepted: false,
                partnerAccepted: false
              }
            };
          });
          setTranscript((current) => [`Offered item #${itemId} x${amount}`, ...current]);
        }}
        onReject={() => {
          setState((current) => ({
            ...current,
            trade: {
              ...current.trade,
              accepted: false,
              partnerAccepted: false,
              myOffer: {
                ...current.trade.myOffer,
                gold: 0,
                items: Array.from({ length: 10 }, () => null)
              }
            }
          }));
          setTranscript((current) => ["Rejected and cleared the local offer", ...current]);
        }}
        onSelectInventorySlot={(slotIndex) => {
          setState((current) => ({
            ...current,
            inventory: { ...current.inventory, selectedSlot: slotIndex },
            trade: {
              ...current.trade,
              accepted: false,
              partnerAccepted: false
            }
          }));
          setTranscript((current) => [
            slotIndex == null ? "Cleared the inventory selection" : `Selected inventory slot ${slotIndex + 1}`,
            ...current
          ]);
        }}
        onSetOfferAmount={(amount) =>
          setState((current) => ({
            ...current,
            trade: { ...current.trade, offerAmount: amount }
          }))
        }
      />

      <SmokeTranscript entries={transcript} title="Trade transcript" />
    </HarnessShell>
  );
}

function createSocialState(): ClientState {
  const next = cloneInitialState();
  next.connection.characterName = "PlaywrightHero";
  next.party.open = true;
  next.party.members = ["PlaywrightHero", "Aster"];
  next.party.leaderName = "PlaywrightHero";
  next.party.invited = false;
  next.party.inviterName = "";
  next.party.safeMode = false;
  next.clan.open = true;
  return next;
}

function SocialSmokePage() {
  const [state, setState] = useState<ClientState>(() => createSocialState());
  const [transcript, setTranscript] = useState<string[]>(["Social smoke route ready."]);

  return (
    <HarnessShell description="Party and clan flows rendered with synthetic browser state." title="Social smoke">
      <section className="panel" data-testid="playwright-social-summary">
        <div className="panel-header">
          <div>
            <p className="eyebrow">State</p>
            <h2>Social status</h2>
          </div>
          <span className="panel-tag">{state.party.safeMode ? "party safe" : "party unsafe"}</span>
        </div>
        <p className="panel-copy compact">
          Clan: {state.clan.name || "none"} · Members: {state.clan.members.length}
        </p>
        <div className="merchant-action-row" style={{ marginTop: "0.75rem" }}>
          <button
            className="ghost-button"
            onClick={() => {
              setState((current) => ({
                ...current,
                clan: createActiveClanState(current.clan)
              }));
              setTranscript((current) => ["Loaded the sample clan snapshot", ...current]);
            }}
            type="button"
          >
            Load sample clan
          </button>
        </div>
      </section>

      <PartyPanel
        state={state}
        onClose={() => {
          setTranscript((current) => ["Closed the party panel", ...current]);
        }}
        onSendChat={(message) => {
          setTranscript((current) => [message, ...current]);
        }}
        onSendPartySafeToggle={() => {
          setState((current) => ({
            ...current,
            party: { ...current.party, safeMode: !current.party.safeMode }
          }));
          setTranscript((current) => [
            state.party.safeMode ? "Party safe mode turned off" : "Party safe mode turned on",
            ...current
          ]);
        }}
      />

      <ClansPanel
        state={state}
        onClose={() => {
          setTranscript((current) => ["Closed the clan panel", ...current]);
        }}
        onSendChat={(message) => {
          setTranscript((current) => [message, ...current]);

          if (message.startsWith("/CREARCLAN ")) {
            const clanName = message.slice("/CREARCLAN ".length).trim();

            setState((current) => ({
              ...current,
              clan: {
                ...createActiveClanState(current.clan),
                name: clanName,
                members: ["PlaywrightHero"],
                onlineMembers: ["PlaywrightHero"],
                rank: "Fundador",
                leaderName: "PlaywrightHero",
                founderName: "PlaywrightHero",
                memberCount: 1,
                pendingRequests: []
              }
            }));
            return;
          }

          if (message.startsWith("/SALIRCLAN")) {
            setState((current) => ({
              ...current,
              clan: {
                ...current.clan,
                name: "",
                members: [],
                onlineMembers: [],
                rank: "",
                leaderName: "",
                founderName: "",
                alignment: "",
                description: "",
                news: "",
                memberCount: 0,
                level: 1,
                currentExp: 0,
                neededExp: 0,
                pendingRequests: []
              }
            }));
          }
        }}
        onSendClanChat={(message) => {
          setTranscript((current) => [`[Clan] ${message}`, ...current]);
        }}
        onRefreshInfo={() => {
          setTranscript((current) => ["Requested clan details", ...current]);
        }}
        onRefreshNews={() => {
          setTranscript((current) => ["Requested clan news", ...current]);
        }}
        onRefreshOnline={() => {
          setTranscript((current) => ["Requested clan online list", ...current]);
        }}
        onRefreshLeaderInfo={() => {
          setTranscript((current) => ["Requested clan leader info", ...current]);
        }}
      />

      <SmokeTranscript entries={transcript} title="Social transcript" />
    </HarnessShell>
  );
}

function createProductCharacter(id: number, name: string): BrowserCharacter {
  return {
    id,
    name,
    level: 12 + id,
    xp: 4000 + id * 250,
    class: "mage",
    class_label: "Mago",
    race: "human",
    race_label: "Humano",
    gender: "male",
    gender_label: "Hombre",
    home_city: "nix",
    home_city_label: "Nix",
    map_id: 47,
    pos_x: 2,
    pos_y: 2,
    dead: false,
    criminal: false,
    gold: 500 + id * 100,
    body_id: 1,
    head_id: 1,
    helmet_id: null,
    weapon_id: null,
    shield_id: null,
    online: false
  };
}

function createProductOptions(): CharacterCreationOptions {
  return {
    races: [{ id: 1, label: "Humano" }],
    genders: [{ id: 1, label: "Hombre" }],
    classes: [{ id: 1, label: "Mago" }],
    home_cities: [{ id: 1, label: "Nix" }],
    head_ranges: {
      "1:1": [{ min: 1, max: 3 }]
    },
    body_ids: {
      "1:1": 1
    },
    defaults: {
      race: 1,
      gender: 1,
      class: 1,
      home_city: 1,
      head: 1
    }
  };
}

function createRankingEntries(): BrowserRankingEntry[] {
  return [
    {
      rank: 1,
      character: {
        ...createProductCharacter(91, "Sirena"),
        kills: 98
      }
    },
    {
      rank: 2,
      character: {
        ...createProductCharacter(92, "Fulgor"),
        kills: 83
      }
    }
  ];
}

function ProductSmokePage() {
  const [route, setRoute] = useState<BrowserRoute>("/");
  const [summary, setSummary] = useState("No character launched yet.");
  const [transcript, setTranscript] = useState<string[]>(["Product smoke route ready."]);

  const api = useMemo<ProductApiClient>(() => {
    const store: {
      account: BrowserAccount | null;
      characters: BrowserCharacter[];
      nextCharacterId: number;
    } = {
      account: null,
      characters: [],
      nextCharacterId: 100
    };

    const options = createProductOptions();
    const ranking = createRankingEntries();

    return {
      fetchBrowserSession: async () => ({
        authenticated: store.account != null,
        account: store.account
      }),
      loginBrowserAccount: async (username, _password) => {
        store.account = {
          id: 1,
          username
        };

        return { account: store.account };
      },
      registerBrowserAccount: async (username, _password) => {
        store.account = {
          id: 1,
          username
        };

        return { account: store.account };
      },
      logoutBrowserAccount: async () => {
        store.account = null;
        return { logout: true };
      },
      fetchCharacterOptions: async () => options,
      fetchBrowserCharacters: async () => ({
        characters: [...store.characters]
      }),
      createBrowserCharacter: async ({ name }) => {
        const character = createProductCharacter(store.nextCharacterId, name);
        store.nextCharacterId += 1;
        store.characters = [...store.characters, character];
        return { character };
      },
      launchBrowserCharacter: async (characterId) => {
        const character =
          store.characters.find((entry) => entry.id === characterId) ??
          createProductCharacter(characterId, `Character ${characterId}`);

        return {
          character,
          credentials: {
            char_id: character.id,
            token: `playwright-${character.id}`
          }
        };
      },
      fetchBrowserRanking: async (_limit) => ({
        entries: ranking
      })
    };
  }, []);

  const previewAssetLoader = useMemo(
    () => async (): Promise<AssetCatalog | null> => null,
    []
  );

  return (
    <HarnessShell
      description="The real browser account and lobby shell with a deterministic in-memory API."
      title="Product smoke"
    >
      <section className="panel" data-testid="playwright-product-summary">
        <div className="panel-header">
          <div>
            <p className="eyebrow">Status</p>
            <h2>Browser product shell</h2>
          </div>
          <span className="panel-tag">{route}</span>
        </div>
        <p className="panel-copy compact" data-testid="playwright-product-launch-summary">
          {summary}
        </p>
      </section>

      <ProductShell
        api={api}
        currentRoute={route}
        endpoint={window.location.origin}
        onClearGameplaySession={() => {
          setTranscript((current) => ["Cleared the saved gameplay session", ...current]);
        }}
        onLaunchCharacter={(character, credentials) => {
          setSummary(`Launched ${character.name} with token ${credentials.token}`);
          setTranscript((current) => [`Launched ${character.name}`, ...current]);
        }}
        onNavigate={(nextRoute) => {
          setRoute(nextRoute);
          setTranscript((current) => [`Navigated to ${nextRoute}`, ...current]);
        }}
        previewAssetLoader={previewAssetLoader}
      />

      <SmokeTranscript entries={transcript} title="Product transcript" />
    </HarnessShell>
  );
}

export function PlaywrightHarness() {
  const pathname = window.location.pathname;

  if (pathname.startsWith("/playwright/session")) {
    return <SessionSpellbookSmoke />;
  }

  if (pathname.startsWith("/playwright/trade")) {
    return <TradeSmokePage />;
  }

  if (pathname.startsWith("/playwright/social")) {
    return <SocialSmokePage />;
  }

  if (pathname.startsWith("/playwright/product")) {
    return <ProductSmokePage />;
  }

  if (pathname.startsWith("/playwright/weather")) {
    return <WeatherSmokePage />;
  }

  if (pathname.startsWith("/playwright/sprites")) {
    return (
      <Suspense fallback={null}>
        <SpritePreviewPage />
      </Suspense>
    );
  }

  return <PlaywrightLanding />;
}
