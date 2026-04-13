import React, { useMemo, useState } from "react";
import ReactDOM from "react-dom/client";
import { createInitialState } from "./app/appReducer";
import type { ClientState } from "./app/types";
import { ClansPanel } from "./ui/ClansPanel";
import { PartyPanel } from "./ui/PartyPanel";
import "./styles.css";

function createHarnessState(): ClientState {
  const initial = createInitialState();

  return {
    ...initial,
    connection: {
      ...initial.connection,
      status: "connected",
      endpoint: "ws://127.0.0.1:7667/ao",
      characterName: "Ari",
      bootstrapPassword: "browser_bootstrap_token",
      lastError: null,
      credentials: null
    },
    world: {
      ...initial.world,
      self: {
        ...initial.world.self,
        name: "Ari",
        charIndex: 42
      }
    },
    party: {
      ...initial.party,
      open: true,
      invited: true,
      inviterName: "Niora",
      members: [],
      leaderName: "",
      safeMode: true
    },
    clan: {
      ...initial.clan,
      open: true,
      name: "Luz del Alba",
      members: ["Ari", "Niora", "Korin"],
      onlineMembers: ["Ari", "Niora"],
      rank: "Lider",
      leaderName: "Ari",
      founderName: "Ari",
      alignment: "Ciudadano",
      description: "Clan de prueba para el harness.",
      news: "Reunion al anochecer.",
      memberCount: 3,
      level: 3,
      currentExp: 12,
      neededExp: 20,
      pendingRequests: ["Tarin"]
    }
  };
}

function HarnessApp() {
  const [state, setState] = useState<ClientState>(() => createHarnessState());
  const [activity, setActivity] = useState<string[]>([]);
  const [surface, setSurface] = useState<"party" | "clan" | "both">("party");

  const log = (message: string) => {
    setActivity((current) => [message, ...current].slice(0, 8));
  };

  const sendChat = (msg: string) => {
    log(msg);

    setState((current) => {
      if (msg.startsWith("/ACEPTARGRUPO")) {
        return {
          ...current,
          party: {
            ...current.party,
            invited: false,
            inviterName: "",
            members: [current.world.self.name, "Lina", "Orion"],
            leaderName: current.world.self.name
          }
        };
      }

      if (msg.startsWith("/PARTY ")) {
        const target = msg.slice("/PARTY ".length).trim();
        return {
          ...current,
          party: {
            ...current.party,
            invited: false,
            inviterName: "",
            members: target.length > 0 ? [current.world.self.name, target] : current.party.members,
            leaderName: current.world.self.name
          }
        };
      }

      if (msg.startsWith("/ECHARGRUPO ")) {
        const target = msg.slice("/ECHARGRUPO ".length).trim();
        return {
          ...current,
          party: {
            ...current.party,
            members: current.party.members.filter((member) => member !== target)
          }
        };
      }

      if (msg.startsWith("/SALIRGRUPO")) {
        return {
          ...current,
          party: {
            ...current.party,
            members: [],
            leaderName: "",
            invited: false,
            inviterName: "",
            safeMode: false
          }
        };
      }

      if (msg.startsWith("/CREARCLAN ")) {
        const target = msg.slice("/CREARCLAN ".length).trim();
        return {
          ...current,
          clan: {
            ...current.clan,
            name: target,
            members: [current.world.self.name],
            onlineMembers: [current.world.self.name],
            rank: "Fundador",
            leaderName: current.world.self.name,
            founderName: current.world.self.name,
            memberCount: 1
          }
        };
      }

      if (msg.startsWith("/INVITARCLAN ")) {
        return current;
      }

      if (msg.startsWith("/CC ")) {
        return current;
      }

      if (msg.startsWith("/SALIRCLAN")) {
        return {
          ...current,
          clan: {
            ...current.clan,
            open: true,
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
        };
      }

      if (msg.startsWith("/ACEPTARCLAN")) {
        return {
          ...current,
          clan: {
            ...current.clan,
            name: "Cabal de Prueba",
            members: [current.world.self.name, "Lina"],
            onlineMembers: [current.world.self.name, "Lina"],
            rank: "Recluta",
            leaderName: "Lina",
            founderName: "Lina",
            memberCount: 2
          }
        };
      }

      return current;
    });
  };

  const sendPartySafeToggle = () => {
    log("/SEGUROGRUPO");
    setState((current) => ({
      ...current,
      party: {
        ...current.party,
        safeMode: !current.party.safeMode
      }
    }));
  };

  const harnessSummary = useMemo(
    () => ({
      partyMembers: state.party.members.length,
      clanMembers: state.clan.members.length,
      safeMode: state.party.safeMode
    }),
    [state.clan.members.length, state.party.members.length, state.party.safeMode]
  );

  return (
    <div className="client-shell" data-testid="party-clan-harness">
      <main className="world-column">
        <section className="panel">
          <div className="panel-header">
            <div>
              <p className="eyebrow">Playwright</p>
              <h1>Party y Clanes</h1>
              <p className="panel-copy">
                Harness local para validar que los paneles usan el estado actual del cliente y
                reaccionan a comandos reales sin tocar backend.
              </p>
            </div>
          </div>

          <div className="status-row">
            <span className="status-pill" data-state="connected">
              {harnessSummary.partyMembers} miembros de party
            </span>
            <span className="status-pill" data-state="connected">
              {harnessSummary.clanMembers} miembros de clan
            </span>
            <span className="status-pill" data-state={harnessSummary.safeMode ? "connected" : "connecting"}>
              Seguro: {harnessSummary.safeMode ? "ON" : "OFF"}
            </span>
          </div>

          <div className="merchant-section" style={{ marginTop: "20px" }}>
            <div className="merchant-section-header">
              <h3>Actividad</h3>
              <span className="panel-tag">últimos comandos</span>
            </div>
            <div className="trade-list" data-testid="harness-activity">
              {activity.length > 0 ? (
                activity.map((entry, index) => (
                  <div className="trade-row" key={`${entry}-${index}`}>
                    <div className="trade-row-copy">
                      <strong>{entry}</strong>
                    </div>
                  </div>
                ))
              ) : (
                <div className="trade-row trade-row-empty">
                  <div className="trade-row-copy">
                    <strong>Aún no se enviaron comandos.</strong>
                  </div>
                </div>
              )}
            </div>
          </div>
        </section>
      </main>

      <aside className="side-panel side-panel-right">
        <div className="hud-stack" style={{ gap: "14px", overflow: "visible" }}>
          <section className="panel">
            <div className="panel-header">
              <div>
                <p className="eyebrow">Surface</p>
                <h2>Social harness</h2>
              </div>
              <span className="panel-tag" data-testid="harness-surface-state">
                {surface}
              </span>
            </div>
            <div className="action-row">
              <button
                className="ghost-button"
                data-testid="harness-show-party"
                onClick={() => setSurface("party")}
                type="button"
              >
                Party
              </button>
              <button
                className="ghost-button"
                data-testid="harness-show-clan"
                onClick={() => setSurface("clan")}
                type="button"
              >
                Clan
              </button>
              <button
                className="ghost-button"
                data-testid="harness-show-both"
                onClick={() => setSurface("both")}
                type="button"
              >
                Ambos
              </button>
            </div>
          </section>

          {surface !== "clan" ? (
            <PartyPanel
              state={state}
              onClose={() => setSurface("clan")}
              onSendChat={sendChat}
              onSendPartySafeToggle={sendPartySafeToggle}
            />
          ) : null}

          {surface !== "party" ? (
            <ClansPanel
              state={state}
              onClose={() => setSurface("party")}
              onSendChat={sendChat}
              onSendClanChat={(msg) => log(`/CC ${msg}`)}
              onRefreshInfo={() => log("refresh clan info")}
              onRefreshNews={() => log("refresh clan news")}
              onRefreshOnline={() => log("refresh clan online")}
              onRefreshLeaderInfo={() => log("refresh clan leader info")}
            />
          ) : null}
        </div>
      </aside>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("app") as HTMLElement).render(
  <React.StrictMode>
    <HarnessApp />
  </React.StrictMode>
);
