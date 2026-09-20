# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Pokémon Auto Chess (v6.11) — an open-source multiplayer auto-battler. One repository contains both the authoritative Colyseus game server and the React/Phaser browser client; they are compiled from the same source tree and share types by direct relative import.

## Local modifications (this clone is NOT a pristine upstream checkout)

This working copy carries a local delta — two commits on top of `origin/master` — that
lets the game run with no internet by pointing the client and server at a local Firebase
Auth emulator. `LOCAL-SETUP.md` has the full rationale and the upstream-sync procedure.

What this changes about working here:

- **`ensureFirebase()` in `app/public/src/network.ts` is the single Firebase init point.**
  Do not add another `firebase.initializeApp(...)` call site. The emulator must be
  configured *before* the SDK restores a persisted session, otherwise the client signs in
  against the emulator while background calls such as `accounts:lookup` still go to
  Google and fail with 400.
- FirebaseUI signs in through its own throwaway app instance, so it only honours
  `emulatorConfig` on its config object — `firebase.auth().useEmulator()` alone does not
  affect it. Both are wired up in `login.tsx`.
- Offline mode is driven by `FIREBASE_AUTH_EMULATOR_HOST` in `.env`. Leave it empty for
  real Firebase. The client bundle must be rebuilt when it changes, because esbuild
  inlines the value at build time.
- `start-offline.cmd` (repository root, deliberately pure ASCII and using `%~dp0`, to
  dodge the console-codepage trap with this repo's non-ASCII path) starts mongo + the
  auth emulator + the game. The supporting infrastructure lives outside the repo in
  `E:\mongodb\`.
- **Never commit these four regenerable files:** `package.json` (only `assetsVersion`
  moves), `app/public/dist/client/sw.js`, `app/public/src/assets/atlas.json`, and
  `edit/assetpack/assetpack-cli-fork/bin/index.js` (a CRLF artefact with no content
  change). `npm run assetpack` regenerates the first three; discard them before
  committing.

## Commands

```bash
npm install          # also runs postinstall: downloads music (degit) + installs edit/assetpack. Slow.

npm run dev          # dev-client (esbuild watch) + dev-server (tsx watch) in parallel
npm run dev-server   # server only: tsx watch ./app/index.ts
npm run dev-client   # client bundle only, esbuild watch

npm run typecheck    # tsc --noEmit — the real safety net (see Testing below)
npm run lint         # biome lint app/  (no write)
npm run check        # biome check --write  (format + autofix)
npm run check:unsafe # biome check --write --unsafe

npm run build        # build-client + build-server (tsc)
npm run build-prod   # build-client + tsc -p tsconfig.prod.json --noCheck
npm start            # run compiled output: app/public/dist/server/app/index.js

npm run check-circular-refs  # dpdm over ./app — circular imports are a known hazard
npm run knip                 # dead-code / unused-export scan
```

Required before the game will boot at all: a `.env` with `MONGO_URI` and the `FIREBASE_*` credentials. Copy `.env-example`; see README for obtaining MongoDB (Atlas or local, database `dev`, collection `botv2` seeded from `db-commands/botv2.json`) and Firebase (auth + admin service-account key). `docker-compose.yaml` wires a local mongo + app if you prefer. Mongo and Firebase are both live dependencies of `beforeListen` in `app/app.config.ts` — you cannot start the server without them.

`npm run assetpack` must be re-run after any change under `app/public/src/assets`. Warning: it rewrites `assetsVersion` in `package.json` and the cache version in `app/public/dist/client/sw.js` as a side effect, leaving an unintended diff you must consciously keep or revert.

## Testing

**There is no test suite, no test framework, and no `test` script.** The only test in the repository is `app/core/abilities/headlong-rush.test.ts`, which uses Node's built-in runner and is wired to nothing:

```bash
npx tsx --test app/core/abilities/headlong-rush.test.ts
```

CI (`.github/workflows/`) runs only `npm install && npm run build` — no lint, no typecheck, no tests. In practice `npm run typecheck` plus `npm run build` is the verification loop.

## Architecture

### Server: four Colyseus rooms

Registered in `app/app.config.ts`; every room uses `@colyseus/command`'s `Dispatcher`, so lifecycle handlers are thin wrappers that dispatch a Command.

| Room | Class | Role |
|---|---|---|
| `lobby` | `CustomLobbyRoom` | Singleton (`autoDispose = false`, unlisted). Chat, room listing, tournaments, roles/boosters. Caches users in memory. |
| `preparation` | `PreparationRoom` | Pre-game staging, max 8. Owner configures rules then starts the game. |
| `game` | `GameRoom` | The actual match: picks, combat, town phases, elo/exp persistence. |
| `after-game` | `AfterGameRoom` | Results screen data. Self-destructs after 120 s. |

Player flow: client joins `lobby` → `JoinOrOpenRoomCommand` creates a `preparation` room → `OnGameStartRequestCommand` creates a `game` room and publishes `game-started` on Redis presence → `PreparationRoom.onGameStart` broadcasts `Transfer.GAME_START` → clients `joinById` the game room → on game end the **client itself** calls `client.create("after-game", …)` (`app/public/src/pages/game.tsx:350`) and then reconnects into it from `/after`.

That last step is the most surprising design choice here: the server never creates the after-game room, and `AfterGameRoom.onCreate` trusts the client-supplied `players` payload verbatim. Treat after-game display data as attacker-controllable and cosmetic-only.

### State synchronization

`app/rooms/states/*.ts` are the room roots (Schema subclasses assigned to `this.state` in `onCreate`). They hold only fields — no simulation logic. `app/models/colyseus-models/*.ts` are the nested Schema classes that fill the state tree; they are not a separate model layer.

Critical: **a field without an `@type` decorator is never sent to clients.** State roots and nested models mix synced and server-only fields freely (e.g. `GameState.time`, `GameState.botManager`, `Simulation.room`). If the client "can't see" a field, suspect a missing `@type` first.

Conversely, **everything with `@type` syncs to every client in the room** — there is no hidden-information channel except Colyseus `@view()`. Exactly three fields use it (`app/models/colyseus-models/player.ts:108,113,114`): `shop`, `shopLocked`, `shopFreeRolls`, scoped per client in `OnJoinCommand`. Any new field that must be private needs `@view()`, or it leaks to all opponents.

The patch rate is the Colyseus default (not overridden); `Encoder.BUFFER_SIZE` is raised to 512 KB in `app/index.ts` because the state payload is large.

### Simulation loop

One `setSimulationInterval` exists in the whole project: `GameRoom.startGame()` (`app/rooms/game-room.ts:694`), running at the Colyseus default ~16.6 ms. Each tick dispatches `OnUpdateCommand` with a `deltaTime` clamped to `MAX_SIMULATION_DELTA_TIME` (50 ms, `app/config/server/network.ts`).

`OnUpdateCommand` (`app/rooms/commands/game-commands.ts:1153`) is the master tick: it drives the phase clock, advances every `Simulation` during `FIGHT`, and updates the mini-game during `TOWN`, then chains to `OnUpdatePhaseCommand`, which cycles `TOWN → PICK → FIGHT`. The server is fully authoritative — the client never re-simulates, it only interpolates the synced entities and renders discrete `Transfer.*` effect messages.

The phase clock lives in the synced state as **two fields with different units**: `GameState.time` is server-only milliseconds, `GameState.roundTime` is synced seconds. Stage durations in `app/config/game/stages.ts` are in seconds. Watch for off-by-1000 mistakes.

### Two unrelated "command" patterns

Do not confuse them:

1. **`@colyseus/command`** — room-level. `Command<Room, Payload>` with `async execute(payload)`, dispatched from message handlers. A command may return another command or an array, which are enqueued and run next (this is how chains like ready → check-auto-start → start-game are built). This is the only place game logic mutates room state.
2. **`SimulationCommand`** (`app/core/simulation-command.ts`) — entity-level. `abstract class SimulationCommand { delay; update(dt) { this.delay -= dt; … } }`, a tick-based timer queue attached to `PokemonEntity.commands`.

### Persistence

- **In-memory only:** all room state, shops, `BotManager`, mini-game state.
- **Redis (via presence, shared across threads):** pending-game / reconnection entries and player timeouts (`app/core/pending-game-manager.ts`), plus pub/sub channels (`game-started`, `room-deleted`, `maintenance`, …).
- **MongoDB** (`app/app.config.ts` connects on `beforeListen`): `user-metadata` is the core user document (elo, exp, level, `pokemonCollection`); also `bot-v2`, `chat-v2`, `detailled-statistic-v2` (per-player-per-game history), aggregated meta/statistic models, `banned-user`, `tournament`, `twitch-blacklisted-streamer`. Note the legacy/v2 duplication (`meta.ts` + `meta-v2.ts`, `items-statistic.ts` + `items-statistic-v2.ts`).

`app/services/cronjobs.ts` runs scheduled maintenance: elo decay, old anonymous account deletion, history pruning, monthly meta recompute.

### Client

Entry: `app/public/src/index.tsx`. **The entire React tree renders only inside `i18n.on("initialized")`** — nothing mounts until translations load. Wrapper chain is `<Provider store>` → `<StrictMode>` → `<Suspense>` → `<BrowserRouter>`.

- **React 19** (`createRoot`), not Preact; **Phaser 4** for the game canvas (plus `phaser4-rex-plugins`), not PixiJS or Phaser 3.
- **Routing:** `react-router` v8, imported from `"react-router"` — *not* `react-router-dom`. **There is no SPA fallback:** every client route has a hand-written `app.get("/lobby", …)` etc. in `app/app.config.ts` returning `index.html`. Adding a client route requires adding the matching Express route.
- **Redux Toolkit** for server-derived state (`stores/`: `network`, `lobby`, `preparation`, `game`, `after`, `boosters`). Configured with `serializableCheck: false` and `enableMapSet()` because Colyseus schema objects live in the store. Typed hooks (`useAppSelector`, `useAppDispatch`) are in `app/public/src/hooks.ts`.
- **User preferences are NOT in Redux.** They live in `app/public/src/preferences.ts` — a hand-rolled observable store backed by localStorage, read imperatively via `preference("renderer")` even from inside Phaser code. Look here for keybindings, volumes, renderer choice, theme, replay retention.
- **Server state → Redux wiring is written inline in page components**, not in a service layer. `bindRoom()` in `app/public/src/pages/game.tsx` is ~600 lines of `$state.listen(...)` / `.onAdd` / `.onChange` callbacks, each dispatching an action. Adding a synced field means touching the schema, that binding, the store reducer, and the consuming component.
- **Networking** is centralised in `app/public/src/network.ts`: a module-level mutable `rooms` singleton with manual reconnection-token bookkeeping (tokens in `localStore` under `LocalStoreKeys.RECONNECTION_*` with per-room TTLs). REST calls are plain `fetch` with Firebase `Authorization: Bearer <idToken>`; the endpoint definitions live in `app/app.config.ts`.
- **Rendering layers:** `app/public/src/game/game-container.ts` owns the `Phaser.Game`; `game/scenes/game-scene.ts` owns `board` / `battle` / item / weather managers; `game/components/board-manager.ts` and `battle-manager.ts` are the PICK/TOWN and BATTLE boards. React HUD elements are laid *over* the canvas using the z-indices in `game/components/depths.ts` (single source of truth). `dom.createContainer: true` lets Phaser host live React trees inside the scene.
- **Replay is a fake room.** `app/public/src/game/replay-room.ts` implements the subset of the Colyseus `Room` surface the renderer reads (backed by a real `SchemaSerializer` fed from recorded frames), so `/replay` reuses the entire game renderer with no server. **Any new room-bound code must branch on `isReplayRoom(room)` (`game/replay-room-id.ts`) or replays break.** The recorder monkey-patches the Colyseus SDK decode seam (`game/recorder.ts`) and flushes to a dedicated Web Worker.

### Shared code / server-client boundary

The client imports server source directly via relative `import type`:

```ts
import type { server } from "../../app.config.ts"   // app/public/src/network.ts
```

`new Client<typeof server>(endpoint)` binds room names to state types. Shared by both sides: `app/types/**` (the wire protocol — `Transfer`, `CloseCodes`, enums), `app/config/**` (balance constants), `app/utils/**`, `app/models/precomputed/**`, and `app/models/colyseus-models/**` (types only). `app/core/**` is server-only except four modules (`collection`, `flower-pots`, and `pokemon-entity` / `simulation` as types) — the client never runs real combat logic.

**There are no path aliases anywhere** (no `paths` in `tsconfig.json`); all imports are deeply relative. Combined with `npm run check-circular-refs`, treat circular imports as a real hazard.

### Game content and the data pipeline

There is no database or CSV as the source of truth for game content — it is all hand-maintained TypeScript constants. MongoDB holds only user/account data.

| Content | Canonical location |
|---|---|
| Per-species stats, types, evolution rules | `app/models/colyseus-models/pokemon.ts` — one `class X extends Pokemon` per species |
| Identity tables (`Pkm`, `PkmIndex`, `PkmFamily`, duos, alt-forms) | `app/types/enum/Pokemon.ts` |
| Items (and recipes) | `app/types/enum/Item.ts`; per-item stat effects in `app/config/game/items.ts` |
| Synergies | `app/types/enum/Synergy.ts` + `app/config/game/synergies.ts` |
| Stages, pools, shop odds, XP, elo | `app/config/game/{stages,pools,shop,experience,elo,battle,board}.ts` |

Both `app/types/enum/Pokemon.ts` and `app/models/colyseus-models/pokemon.ts` are enormous and *look* generated but are **hand-edited**. Adding a Pokémon means updating the enums, adding a class, and registering it in `PokemonClasses` (typed `Record<Pkm, …>`, so TS will force you).

`app/models/precomputed/*.ts` are **not** built artifacts — they are runtime indexes computed as an import side effect (they instantiate every `Pkm` via `PokemonFactory` on first import, which is why `precompute-*` `console.time` output appears on every server boot). **The README's instruction to run `npm run precompute` is stale** — that script and `gen/precompute-all.ts` were deleted in commit `0da47b975`. To apply a data change, just restart the server.

`gen/` holds one-off scripts (`csv-export` dumps a balance spreadsheet nothing reads; `check-labels` reports extra i18n keys; `add-speed-stat` is a **codemod that rewrites `pokemon.ts` in place** and would clobber hand-tuned balance — do not run it casually). `edit/` holds sprite ingestion (`add-pokemon.ts`, requires the proprietary TexturePacker CLI plus a SpriteCollab checkout) and `edit/assetpack`, which is a **second npm project** with its own lockfile and two vendored forks imported by relative path.

`app/config/index.ts` is a barrel but does **not** re-export `game/{abilities,dishes,expeditions,gadgets,music,patches}.ts` — import those by full path.

## Conventions and gotchas

- **Formatting** is Biome (not ESLint/Prettier): 2-space indent, 80 cols, double quotes, **no semicolons** (`semicolons: "asNeeded"`), no trailing commas. `linter.rules.recommended` is **false** — only explicitly listed rules apply, and `useImportType: "error"` is one of them (always use `import type` for type-only imports).
- **Biome only covers `app/`.** `gen/`, `edit/`, `db-commands/`, and `export/` are neither linted nor type-checked (also excluded from `tsconfig.json`'s `include`), so scripts there rot silently.
- **`strict: true` but `noImplicitAny: false`** — `strict` does not mean full strictness here, and explicit `any` is allowed by both TS and Biome. `tsc --noEmit` is still the primary correctness check.
- **Translations live under `dist/`** (`app/public/dist/client/locales/<lng>/translation.json`) and are committed there. There is no `app/public/src/locales`. `app/types/locales.ts` imports the generated English file, so **typecheck depends on a build artifact existing in `dist/`**.
- **`assetpack` bumps `assetsVersion`** in `package.json`, which is the cache-busting key for both the service worker and asset URLs. Stale-asset bugs usually mean it wasn't bumped.
- **React `StrictMode` double-invokes effects** in dev; the codebase relies on `useRef` guards throughout.
- **`ecosystem.config.js` uses PM2 fork mode deliberately** — a comment warns against cluster mode. In multi-thread mode only the thread on port 2569 creates the lobby room and runs cron jobs.
- **Room metadata is load-bearing cluster-wide** — rooms are found via `matchMaker.query({ …metadata })` for listings, tournament brackets, and deletion. Changing a `setMetadata` shape ripples into the lobby UI.
- **Anti-abuse rules are scattered** and easy to break: `givePlayerTimeout` (5-minute lockout on abandoning a live game), removal from `players` if leaving before stage 6 without consent, `MinStageForGameToCount` gating xp/elo, and `MAX_LOADING_TIME` (3-minute force-start).
- **`onLeave` does not imply the player is gone** — `GameRoom.onLeave` reconciles against the Redis `pending_game` entry to detect a duplicate leave after a reconnect elsewhere.
- **Command handlers re-derive the actor from `client.auth.uid`** rather than trusting an id in the payload. Preserve this; only `OnOverwriteBoardCommand` and `Transfer.DEV` are gated, and `Transfer.DEV` checks `process.env.MODE === "dev"`.
- `db-commands/` is a manual, versioned migration graveyard (`db-commands/<version>/`) — nothing there runs automatically.
- Stale artifacts with no consumer: `app/models/precomputed/tracker.json` (6 MB) and `app/models/precomputed/pokemons-data.csv`.
