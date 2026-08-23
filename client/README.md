# Argentum Web Client

Standalone web client for the Elixir server.

This is where the serious browser client should grow without turning
`apps/ao_tcp_gateway/priv/static/test_client.html` into a permanent product UI.

## Stack

- `Vite` for dev/build
- `TypeScript` with strict type checking
- `React` for UI panels and app shell
- `Pixi.js` for the world renderer

## Goals

- Keep `test_client.html` as the protocol/debug fallback client
- Reuse the working AO20 packet/runtime behavior from the debug client
- Move the real game UI into typed, modular code
- Grow the client in phases alongside the server roadmap

## Structure

```text
client/
├── index.html
├── package.json
├── vite.config.ts
├── tsconfig.json
└── src/
    ├── app/           # React app shell + reducer/state
    ├── net/           # WebSocket session + bootstrap flow
    ├── protocol/      # AO20 packet encode/decode bridge
    ├── render/        # Pixi world renderer
    └── ui/            # Inventory, HUD, chat, packet log, panels
```

## Migration plan

1. Move AO20 packet encode/decode helpers out of `test_client.html`
2. Move WebSocket login/session flow and session token handling
3. Replace placeholder world rendering with real map/entity rendering from server assets
4. Keep debug-only tools behind a dev overlay instead of making them the whole client
5. Historical only: active browser-product work now follows the root
   [`ROADMAP.md`](../ROADMAP.md) and targets `client-rs`

## Commands

```bash
nix develop --command make client.dev
nix develop --command make client.typecheck
nix develop --command make client.build
```

After `make client.build`, the Elixir gateway serves the built client at:

```bash
http://localhost:7667/client/
```

Direct npm usage also works inside the nix shell:

```bash
nix develop
cd client
npm install
npm run dev
```

The debug client is still the fallback:

- `apps/ao_tcp_gateway/priv/static/test_client.html` = protocol/debug client
- `client/` = browser client
