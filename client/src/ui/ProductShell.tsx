import { useEffect, useMemo, useState } from "react";
import type { BrowserRoute } from "../app/browserRoutes";
import type { AssetCatalog } from "../render/assetCatalog";
import {
  createBrowserCharacter,
  fetchBrowserCharacters,
  fetchBrowserRanking,
  fetchBrowserSession,
  fetchCharacterOptions,
  launchBrowserCharacter,
  loginBrowserAccount,
  logoutBrowserAccount,
  registerBrowserAccount,
  type BrowserAccount,
  type BrowserCharacter,
  type BrowserRankingEntry,
  type CharacterCreationOptions
} from "../product/api";
import { CharacterSpritePreview } from "./CharacterSpritePreview";

interface ProductShellProps {
  assetCatalog: AssetCatalog | null;
  assetStatus: "loading" | "ready" | "error";
  assetError: string | null;
  currentRoute: BrowserRoute;
  onNavigate: (route: BrowserRoute) => void;
  onLaunchCharacter: (character: BrowserCharacter, credentials: { char_id: number; token: string }) => void;
  onClearGameplaySession: () => void;
}

interface CreateFormState {
  name: string;
  race: number;
  gender: number;
  class: number;
  homeCity: number;
  head: number;
}

function headChoicesFor(options: CharacterCreationOptions | null, race: number, gender: number) {
  const ranges = options?.head_ranges[`${race}:${gender}`] ?? [];
  return ranges.flatMap((range) =>
    Array.from({ length: range.max - range.min + 1 }, (_, index) => range.min + index)
  );
}

function defaultCreateForm(options: CharacterCreationOptions): CreateFormState {
  return {
    name: "",
    race: options.defaults.race,
    gender: options.defaults.gender,
    class: options.defaults.class,
    homeCity: options.defaults.home_city,
    head: options.defaults.head
  };
}

export function ProductShell({
  assetCatalog,
  assetStatus,
  assetError,
  currentRoute,
  onNavigate,
  onLaunchCharacter,
  onClearGameplaySession
}: ProductShellProps) {
  const [account, setAccount] = useState<BrowserAccount | null>(null);
  const [sessionLoading, setSessionLoading] = useState(true);
  const [sessionError, setSessionError] = useState<string | null>(null);
  const [characters, setCharacters] = useState<BrowserCharacter[]>([]);
  const [charactersLoading, setCharactersLoading] = useState(false);
  const [ranking, setRanking] = useState<BrowserRankingEntry[]>([]);
  const [rankingLoading, setRankingLoading] = useState(false);
  const [options, setOptions] = useState<CharacterCreationOptions | null>(null);
  const [optionsLoading, setOptionsLoading] = useState(false);
  const [authMode, setAuthMode] = useState<"login" | "register">("login");
  const [authName, setAuthName] = useState("");
  const [authPassword, setAuthPassword] = useState("");
  const [authConfirm, setAuthConfirm] = useState("");
  const [createForm, setCreateForm] = useState<CreateFormState | null>(null);
  const [selectedCharacterId, setSelectedCharacterId] = useState<number | null>(null);
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [actionNotice, setActionNotice] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setSessionLoading(true);
    setSessionError(null);

    void fetchBrowserSession()
      .then((payload) => {
        if (cancelled) {
          return;
        }

        setAccount(payload.account);
      })
      .catch((error) => {
        if (!cancelled) {
          setSessionError(error instanceof Error ? error.message : "Could not load browser session.");
        }
      })
      .finally(() => {
        if (!cancelled) {
          setSessionLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!account) {
      setCharacters([]);
      setSelectedCharacterId(null);
      return;
    }

    let cancelled = false;
    setCharactersLoading(true);

    void fetchBrowserCharacters()
      .then((payload) => {
        if (!cancelled) {
          setCharacters(payload.characters);
        }
      })
      .catch((error) => {
        if (!cancelled) {
          setActionError(error instanceof Error ? error.message : "Could not load character list.");
        }
      })
      .finally(() => {
        if (!cancelled) {
          setCharactersLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [account]);

  useEffect(() => {
    if (currentRoute !== "/ranking") {
      return;
    }

    let cancelled = false;
    setRankingLoading(true);

    void fetchBrowserRanking()
      .then((payload) => {
        if (!cancelled) {
          setRanking(payload.entries);
        }
      })
      .catch((error) => {
        if (!cancelled) {
          setActionError(error instanceof Error ? error.message : "Could not load ranking.");
        }
      })
      .finally(() => {
        if (!cancelled) {
          setRankingLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [currentRoute]);

  useEffect(() => {
    if (currentRoute !== "/create-character" && account == null) {
      return;
    }

    if (options || optionsLoading) {
      return;
    }

    let cancelled = false;
    setOptionsLoading(true);

    void fetchCharacterOptions()
      .then((payload) => {
        if (!cancelled) {
          setOptions(payload);
          setCreateForm((current) => current ?? defaultCreateForm(payload));
        }
      })
      .catch((error) => {
        if (!cancelled) {
          setActionError(
            error instanceof Error ? error.message : "Could not load character creation options."
          );
        }
      })
      .finally(() => {
        if (!cancelled) {
          setOptionsLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [account, currentRoute, options, optionsLoading]);

  useEffect(() => {
    if (characters.length === 0) {
      setSelectedCharacterId(null);
      return;
    }

    setSelectedCharacterId((current) =>
      current != null && characters.some((character) => character.id === current)
        ? current
        : characters[0].id
    );
  }, [characters]);

  const headChoices = useMemo(() => {
    if (!createForm) {
      return [];
    }

    return headChoicesFor(options, createForm.race, createForm.gender);
  }, [createForm, options]);

  useEffect(() => {
    if (!createForm || headChoices.length === 0) {
      return;
    }

    if (!headChoices.includes(createForm.head)) {
      setCreateForm((current) => (current ? { ...current, head: headChoices[0] } : current));
    }
  }, [createForm, headChoices]);

  const selectedCharacter =
    selectedCharacterId == null
      ? null
      : characters.find((character) => character.id === selectedCharacterId) ?? null;

  const createPreviewBodyId =
    createForm && options ? options.body_ids[`${createForm.race}:${createForm.gender}`] ?? 1 : 1;

  async function handleAuthSubmit() {
    setBusyAction("auth");
    setActionError(null);
    setActionNotice(null);

    try {
      if (authMode === "register") {
        if (authPassword !== authConfirm) {
          throw new Error("Passwords do not match.");
        }

        const payload = await registerBrowserAccount(authName, authPassword);
        setAccount(payload.account);
        setActionNotice("Account created. You can create a character now.");
      } else {
        const payload = await loginBrowserAccount(authName, authPassword);
        setAccount(payload.account);
        setActionNotice("Account ready.");
      }

      setAuthPassword("");
      setAuthConfirm("");
      onNavigate("/");
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "Authentication failed.");
    } finally {
      setBusyAction(null);
    }
  }

  async function handleLogout() {
    setBusyAction("logout");
    setActionError(null);
    setActionNotice(null);

    try {
      await logoutBrowserAccount();
      setAccount(null);
      setCharacters([]);
      onClearGameplaySession();
      setActionNotice("Signed out.");
      onNavigate("/");
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "Could not sign out.");
    } finally {
      setBusyAction(null);
    }
  }

  async function handleCreateCharacter() {
    if (!createForm) {
      return;
    }

    setBusyAction("create-character");
    setActionError(null);
    setActionNotice(null);

    try {
      const payload = await createBrowserCharacter({
        name: createForm.name,
        race: createForm.race,
        gender: createForm.gender,
        class: createForm.class,
        head: createForm.head,
        home_city: createForm.homeCity
      });

      setCharacters((current) => [...current, payload.character]);
      setSelectedCharacterId(payload.character.id);
      setActionNotice(`Character ${payload.character.name} created.`);
      onNavigate("/");
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "Could not create character.");
    } finally {
      setBusyAction(null);
    }
  }

  async function handleLaunchSelectedCharacter() {
    if (!selectedCharacter) {
      return;
    }

    setBusyAction("launch-character");
    setActionError(null);
    setActionNotice(null);

    try {
      const payload = await launchBrowserCharacter(selectedCharacter.id);
      onLaunchCharacter(payload.character, payload.credentials);
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "Could not launch character.");
    } finally {
      setBusyAction(null);
    }
  }

  return (
    <div className="product-shell">
      <main className="product-main">
        <section className="panel product-hero">
          <div>
            <p className="eyebrow">Argentum Browser</p>
            <h1>Account, lobby, and world launch stay outside the render loop.</h1>
            <p className="panel-copy">
              Browser auth and character selection run over HTTP. Gameplay still starts with the
              existing WebSocket client and renderer.
            </p>
          </div>
          <div className="product-nav">
            <button
              className={`ghost-button ${currentRoute === "/" ? "tab-active" : ""}`}
              onClick={() => onNavigate("/")}
              type="button"
            >
              Lobby
            </button>
            <button
              className={`ghost-button ${currentRoute === "/ranking" ? "tab-active" : ""}`}
              onClick={() => onNavigate("/ranking")}
              type="button"
            >
              Ranking
            </button>
            {account ? (
              <button
                className={`ghost-button ${currentRoute === "/create-character" ? "tab-active" : ""}`}
                onClick={() => onNavigate("/create-character")}
                type="button"
              >
                Create Character
              </button>
            ) : null}
            <button className="ghost-button" onClick={() => onNavigate("/play")} type="button">
              Advanced Game Client
            </button>
          </div>
        </section>

        {sessionError ? <section className="panel product-banner danger">{sessionError}</section> : null}
        {actionError ? <section className="panel product-banner danger">{actionError}</section> : null}
        {actionNotice ? <section className="panel product-banner success">{actionNotice}</section> : null}

        {currentRoute === "/ranking" ? (
          <section className="panel product-ranking-panel">
            <div className="panel-header">
              <div>
                <p className="eyebrow">General</p>
                <h2>Ranking</h2>
              </div>
              <span className="panel-tag">{rankingLoading ? "Loading" : `${ranking.length} entries`}</span>
            </div>
            <div className="product-ranking-list">
              {ranking.map((entry) => (
                <article className="product-ranking-row" key={`${entry.rank}-${entry.character.id}`}>
                  <div className="product-ranking-rank">{entry.rank}</div>
                  <CharacterSpritePreview
                    assetCatalog={assetCatalog}
                    bodyId={entry.character.body_id}
                    compact
                    headId={entry.character.head_id}
                    helmetId={entry.character.helmet_id}
                    name={entry.character.name}
                    shieldId={entry.character.shield_id}
                    weaponId={entry.character.weapon_id}
                  />
                  <div className="product-ranking-copy">
                    <strong>{entry.character.name}</strong>
                    <small>
                      {entry.character.class_label} · Nivel {entry.character.level} · {entry.character.kills} bajas
                    </small>
                  </div>
                </article>
              ))}
              {!rankingLoading && ranking.length === 0 ? (
                <p className="panel-copy compact">No ranking data is available yet.</p>
              ) : null}
            </div>
          </section>
        ) : null}

        {currentRoute === "/create-character" ? (
          <section className="panel product-create-panel">
            <div className="panel-header">
              <div>
                <p className="eyebrow">Creation</p>
                <h2>Create Character</h2>
              </div>
              <button className="ghost-button" onClick={() => onNavigate("/")} type="button">
                Back To Lobby
              </button>
            </div>

            {!account ? (
              <p className="panel-copy">Sign in first. Character creation belongs to the account lobby flow.</p>
            ) : !createForm || !options ? (
              <p className="panel-copy">{optionsLoading ? "Loading character rules..." : "Character rules missing."}</p>
            ) : (
              <div className="product-create-layout">
                <div className="product-form-grid">
                  <label className="field">
                    <span>Name</span>
                    <input
                      onChange={(event) =>
                        setCreateForm((current) => (current ? { ...current, name: event.target.value } : current))
                      }
                      type="text"
                      value={createForm.name}
                    />
                  </label>

                  <label className="field">
                    <span>Race</span>
                    <select
                      onChange={(event) =>
                        setCreateForm((current) =>
                          current ? { ...current, race: Number(event.target.value) } : current
                        )
                      }
                      value={createForm.race}
                    >
                      {options.races.map((race) => (
                        <option key={race.id} value={race.id}>
                          {race.label}
                        </option>
                      ))}
                    </select>
                  </label>

                  <label className="field">
                    <span>Gender</span>
                    <select
                      onChange={(event) =>
                        setCreateForm((current) =>
                          current ? { ...current, gender: Number(event.target.value) } : current
                        )
                      }
                      value={createForm.gender}
                    >
                      {options.genders.map((gender) => (
                        <option key={gender.id} value={gender.id}>
                          {gender.label}
                        </option>
                      ))}
                    </select>
                  </label>

                  <label className="field">
                    <span>Class</span>
                    <select
                      onChange={(event) =>
                        setCreateForm((current) =>
                          current ? { ...current, class: Number(event.target.value) } : current
                        )
                      }
                      value={createForm.class}
                    >
                      {options.classes.map((entry) => (
                        <option key={entry.id} value={entry.id}>
                          {entry.label}
                        </option>
                      ))}
                    </select>
                  </label>

                  <label className="field">
                    <span>Home City</span>
                    <select
                      onChange={(event) =>
                        setCreateForm((current) =>
                          current ? { ...current, homeCity: Number(event.target.value) } : current
                        )
                      }
                      value={createForm.homeCity}
                    >
                      {options.home_cities.map((city) => (
                        <option key={city.id} value={city.id}>
                          {city.label}
                        </option>
                      ))}
                    </select>
                  </label>

                  <div className="product-head-picker">
                    <span>Head</span>
                    <div className="product-head-picker-row">
                      <button
                        className="ghost-button"
                        onClick={() =>
                          setCreateForm((current) => {
                            if (!current || headChoices.length === 0) {
                              return current;
                            }

                            const index = headChoices.indexOf(current.head);
                            const nextIndex = index <= 0 ? headChoices.length - 1 : index - 1;
                            return { ...current, head: headChoices[nextIndex] };
                          })
                        }
                        type="button"
                      >
                        Prev
                      </button>
                      <strong>#{createForm.head}</strong>
                      <button
                        className="ghost-button"
                        onClick={() =>
                          setCreateForm((current) => {
                            if (!current || headChoices.length === 0) {
                              return current;
                            }

                            const index = headChoices.indexOf(current.head);
                            const nextIndex = index >= headChoices.length - 1 ? 0 : index + 1;
                            return { ...current, head: headChoices[nextIndex] };
                          })
                        }
                        type="button"
                      >
                        Next
                      </button>
                    </div>
                    <small>{headChoices.length} valid heads for this race and gender.</small>
                  </div>

                  <div className="product-form-actions">
                    <button
                      className="ghost-button"
                      disabled={busyAction === "create-character"}
                      onClick={handleCreateCharacter}
                      type="button"
                    >
                      {busyAction === "create-character" ? "Creating..." : "Create Character"}
                    </button>
                  </div>
                </div>

                <div className="product-selected-card">
                  <CharacterSpritePreview
                    assetCatalog={assetCatalog}
                    bodyId={createPreviewBodyId}
                    headId={createForm.head}
                    name={createForm.name || "Nuevo"}
                  />
                  <div>
                    <p className="eyebrow">Preview</p>
                    <h3>{createForm.name || "New Character"}</h3>
                    <p className="panel-copy compact">
                      {options.races.find((race) => race.id === createForm.race)?.label} ·{" "}
                      {options.genders.find((gender) => gender.id === createForm.gender)?.label} ·{" "}
                      {options.classes.find((entry) => entry.id === createForm.class)?.label}
                    </p>
                  </div>
                </div>
              </div>
            )}
          </section>
        ) : null}

        {currentRoute === "/" ? (
          <section className="panel product-lobby-panel">
            <div className="panel-header">
              <div>
                <p className="eyebrow">{account ? "Lobby" : "Account"}</p>
                <h2>{account ? "Character Selection" : "Sign In Or Register"}</h2>
              </div>
              {account ? (
                <button className="ghost-button" onClick={handleLogout} type="button">
                  {busyAction === "logout" ? "Signing Out..." : "Sign Out"}
                </button>
              ) : null}
            </div>

            {!account ? (
              <div className="product-auth-layout">
                <div className="product-auth-tabs">
                  <button
                    className={`ghost-button ${authMode === "login" ? "tab-active" : ""}`}
                    onClick={() => setAuthMode("login")}
                    type="button"
                  >
                    Login
                  </button>
                  <button
                    className={`ghost-button ${authMode === "register" ? "tab-active" : ""}`}
                    onClick={() => setAuthMode("register")}
                    type="button"
                  >
                    Register
                  </button>
                </div>
                <label className="field">
                  <span>Account Name</span>
                  <input onChange={(event) => setAuthName(event.target.value)} type="text" value={authName} />
                </label>
                <label className="field">
                  <span>Password</span>
                  <input
                    onChange={(event) => setAuthPassword(event.target.value)}
                    type="password"
                    value={authPassword}
                  />
                </label>
                {authMode === "register" ? (
                  <label className="field">
                    <span>Confirm Password</span>
                    <input
                      onChange={(event) => setAuthConfirm(event.target.value)}
                      type="password"
                      value={authConfirm}
                    />
                  </label>
                ) : null}
                <div className="product-form-actions">
                  <button className="ghost-button" disabled={busyAction === "auth"} onClick={handleAuthSubmit} type="button">
                    {busyAction === "auth" ? "Working..." : authMode === "register" ? "Create Account" : "Sign In"}
                  </button>
                </div>
              </div>
            ) : (
              <div className="product-lobby-layout">
                <div className="product-character-list">
                  {characters.map((character) => (
                    <button
                      className={`product-character-row ${
                        selectedCharacterId === character.id ? "product-character-row-selected" : ""
                      }`}
                      key={character.id}
                      onClick={() => setSelectedCharacterId(character.id)}
                      type="button"
                    >
                      <CharacterSpritePreview
                        assetCatalog={assetCatalog}
                        bodyId={character.body_id}
                        compact
                        headId={character.head_id}
                        helmetId={character.helmet_id}
                        name={character.name}
                        shieldId={character.shield_id}
                        weaponId={character.weapon_id}
                      />
                      <span className="product-character-row-copy">
                        <strong>{character.name}</strong>
                        <small>
                          {character.class_label} · Nivel {character.level}
                        </small>
                      </span>
                      <span className="panel-tag">{character.online ? "Online" : "Offline"}</span>
                    </button>
                  ))}

                  {!charactersLoading && characters.length === 0 ? (
                    <div className="product-empty-state">
                      <p className="panel-copy compact">
                        This account has no characters yet. Create one, then launch the gameplay
                        client with `login_existing_char`.
                      </p>
                      <button className="ghost-button" onClick={() => onNavigate("/create-character")} type="button">
                        Create First Character
                      </button>
                    </div>
                  ) : null}
                </div>

                <div className="product-selected-card">
                  {selectedCharacter ? (
                    <>
                      <CharacterSpritePreview
                        assetCatalog={assetCatalog}
                        bodyId={selectedCharacter.body_id}
                        headId={selectedCharacter.head_id}
                        helmetId={selectedCharacter.helmet_id}
                        name={selectedCharacter.name}
                        shieldId={selectedCharacter.shield_id}
                        weaponId={selectedCharacter.weapon_id}
                      />
                      <div>
                        <p className="eyebrow">Selected</p>
                        <h3>{selectedCharacter.name}</h3>
                        <p className="panel-copy compact">
                          {selectedCharacter.race_label} · {selectedCharacter.class_label} ·{" "}
                          {selectedCharacter.home_city_label}
                        </p>
                      </div>
                      <div className="status-row">
                        <span className="panel-tag">Nivel {selectedCharacter.level}</span>
                        <span className="panel-tag">Mapa {selectedCharacter.map_id}</span>
                        <span className="panel-tag">{selectedCharacter.online ? "Online" : "Offline"}</span>
                      </div>
                      <div className="product-form-actions">
                        <button
                          className="ghost-button"
                          disabled={busyAction === "launch-character"}
                          onClick={handleLaunchSelectedCharacter}
                          type="button"
                        >
                          {busyAction === "launch-character" ? "Launching..." : "Play Selected Character"}
                        </button>
                        <button className="ghost-button" onClick={() => onNavigate("/create-character")} type="button">
                          Create Another
                        </button>
                      </div>
                    </>
                  ) : (
                    <p className="panel-copy compact">
                      {charactersLoading ? "Loading character list..." : "Select a character to launch the game client."}
                    </p>
                  )}
                </div>
              </div>
            )}
          </section>
        ) : null}
      </main>

      <aside className="product-side">
        <section className="panel product-side-card">
          <p className="eyebrow">Bootstrap</p>
          <h3>Asset State</h3>
          <p className="panel-copy compact">
            {assetStatus === "ready"
              ? "Sprite and metadata indices are ready for lobby previews and gameplay launch."
              : assetStatus === "error"
                ? assetError ?? "The browser client could not load the shared sprite metadata."
                : "Loading the shared sprite and metadata indices used by the browser client."}
          </p>
        </section>

        <section className="panel product-side-card">
          <p className="eyebrow">Session</p>
          <h3>{sessionLoading ? "Checking account session..." : account ? account.username : "No account session"}</h3>
          <p className="panel-copy compact">
            {account
              ? "HTTP account state lives here. Gameplay reconnect tokens only appear after you launch a specific character."
              : "Sign in or register in the browser shell. The gameplay socket should not be the primary account entry point."}
          </p>
        </section>
      </aside>
    </div>
  );
}
