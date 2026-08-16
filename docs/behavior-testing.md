# Making the game do things: capabilities, edges, and how to test them

This document answers three questions. What can this library make Melee
do, and how sure are we of each claim? Where are the semantic edges —
the places where what we (and Python libmelee) can express about the
game runs out? And when you want a *specific* behavior out of the game,
how do you drive it and how do you write a test that can't lie to you?

Statuses: **live-verified** (a tagged test or recorded live run proves
it), **measured** (empirical coordinates/timings with evidence recorded
next to the constant), **ported** (semantics match Python libmelee,
unit/golden tested, not separately proven live).

## Capability catalog

### Observing the game

| Capability | Module | Status |
|---|---|---|
| Per-frame game snapshot (positions, actions, percent, stocks, shield, hitstun, projectiles) | `Melee.GameState` via `Melee.Console` | live-verified; differential vs peppi: 2,625 replays, ~1.34B field comparisons, zero divergences |
| Menu-state visibility (scene, submenu, cursors) | `Melee.Events.Menu` + gecko code | live-verified (all menu work depends on it) |
| Rollback-aware frame delivery (skip or surface rollback frames) | `Melee.Console` | ported + unit-tested (`rollback_test.exs`) |
| Typed gameplay events (KO vs SD by trajectory, shield breaks, game boundaries) | `Melee.GameEvents` | unit-tested; KO/SD classifier is trajectory-based (hitstun-since-last-safe), not the percent heuristic |
| Replay files through the live decoder, incl. pre-2.2.0 | `Melee.SlpFile` | verified 400/400 old replays; bulk parsing stays peppi's job |
| Attack/hitbox/frame-data queries | `Melee.FrameData` | ported (framedata.py) |

### Acting on the game

| Capability | Module | Status |
|---|---|---|
| Button/analog input at 60fps over named pipes | `Melee.Controller` | live-verified (`--only dolphin_gameplay`: the character demonstrably obeys the stick in a running match); analog quantization float-exact vs Python. Caveat: on the ExiAI build, in-game input requires `blocking_input: true` — menus work either way |
| Full menu navigation: boot screens → CSS → stage select → match | `Melee.MenuHelper` | live-verified end-to-end |
| Character select on any port, human or CPU, incl. CPU level slider | `Melee.MenuHelper` | live-verified on ports 1-4; the measurements are codified as a rerunnable test (`--only dolphin_css`) |
| In-game nametag create + select, persisted to a real save | `Melee.MenuHelper` + `memory_card: :folder` | live-verified (`--only dolphin_nametag`) |
| Slippi Direct connect-code entry and netplay matchmaking | `Melee.MenuHelper`, `Melee.Dolphin` (user.json) | live-verified both sides (`--only netplay_direct`) |
| Frozen Stadium toggle | `Melee.MenuHelper` | live-verified (edge-driven) |

### Running the emulator

| Capability | Module | Status |
|---|---|---|
| Launch/configure/stop Dolphin (gecko codes, pads, cards, user.json, launcher autodetection, version probe) | `Melee.Dolphin`, `Melee.DolphinConfig` | live-verified across all three local builds |
| Orphan-proof spawning (emulator dies with the BEAM, any death mode) | `Melee.Dolphin` spawn shim | live-verified (fd-3 stdin watcher; see commit for the smoke test) |
| Supervised session with correct startup order and restart semantics | `Melee.Session` | live-verified (`--only dolphin_session`) |
| Multi-instance orchestration | `Melee.SessionPool` | unit-tested; used for parallel self-play |
| Opt-in console reconnect with parser reset | `Melee.Console` | unit-tested |
| Swappable transport: pure-BEAM ENet (default) or Rust NIF | `Melee.Transport.{EnetBeam,EnetNif}` | both live-verified against real Dolphin |

## Semantic edges

### Edges shared with Python libmelee (the game itself is the wall)

- **Menus are nearly opaque.** Scene id, submenu, a selection index,
  four cursor positions — that is the entire vocabulary. No "tag list
  is open" flag, no list contents, no button labels. Everything else is
  measured coordinates and frame counts (`docs/melee-menus.md`).
- **CSS fields lie until acted on.** `character` reports the *hovered*
  portrait; `controller_status` reads unplugged until the port locks a
  character; `submenu` goes stale after the keyboard closes;
  `is_holding_cpu_slider` survives losing the slider.
- **CSS state vanishes past the CSS.** At stage select the per-port
  CSS fields stop updating, so cross-port gates must only bite at the
  CSS (two live stalls came from violating this).
- **Some scenes are nameless.** Boot prompts and the Slippi log-in
  screen arrive as `0xFF` (and one still-untyped `0x28` boot scene);
  recovery is heuristic (A briefly, then B).
- **Fountain of Dreams platform heights** are not modeled (moving), and
  `FrameData` range projections ignore current momentum — both are
  upstream TODOs too.
- **Frame data is NTSC 1.02 Dolphin.** No PAL, no other versions.

### Where this port exceeds Python libmelee

- Typed gameplay event stream (`Melee.GameEvents`) with a
  trajectory-based KO/SD classifier.
- Supervision: `Melee.Session`/`SessionPool` own process lifecycle;
  the spawn shim makes emulator leaks structurally impossible.
- Pre-2.2.0 replay files parse (`Melee.SlpFile` manual bookends).
- Opt-in mid-stream reconnect with correct parser reset.
- A pure-BEAM transport — no native code in the default install.
- Menu measurements carry their evidence and counter-examples inline.

### Where Python libmelee does things this port does not

- **Real hardware.** Python can talk to an actual Wii/console over
  Slippstream and drive a GameCube controller adapter. This port is
  Dolphin-only.
- **Some convenience surface** (e.g. `techskill.py` helpers) was
  deliberately not ported.

## How to test a specific behavior

The pattern every live test here follows:

1. **Drive with `Melee.Probe`** (test-only, `MIX_ENV=test`): it owns
   the step loop, cursor steering (`goto!/4`), button pulses
   (`tap!/3`), condition waits (`until!/4`), and per-port MenuHelpers
   (`drive!/4`). Dolphin only advances when stepped — an input that is
   set but never stepped does nothing.
2. **Find a gamestate-observable signature** for the thing you care
   about, because pixels are a last resort. Worked examples: an open
   tag list = the hand *yanked* up into the rows and x pinned at
   exactly `-25.2 + 15.4*(N-1)`; "CPU configured" = `cpu_level` +
   `controller_status`, never `coin_down`; keyboard entry =
   `menu_selection == 45`.
3. **When the gamestate can't see it, screenshot.** Windowed OGL +
   `grim` (recipe in `docs/melee-menus.md`). The 2026-08-14 session
   burned four runs on a wrong theory that one screenshot dispelled.
4. **Assert on things that can't be true by accident**: a tag present
   in GAME_START, a `.gci` written to a folder wiped at test start,
   `cpu_level == 9` in-game. Never step counts (polling coalesces
   them) — guard with `Probe.elapsed_ms/1` wall clock, with a floor so
   a vacuous pass fails.
5. **Tag it** (`@moduletag :dolphin`, plus a capability tag) and add it
   to the smoke-test catalog in `docs/getting-started.md` with the
   command and what a pass looks like, so anyone can rerun the claim.
6. **Sequence cross-port flows** and gate only at the CSS — the two
   rules that produced every stall we have debugged live.

## Where interactions can still get more stable, validated, and faster

### Stability (ordered by expected value)

1. **Surface Dolphin's death.** The launcher's port gets
   `:exit_status`, but nothing reads it — a crashed emulator is
   invisible until a step times out or a pipe write EPIPEs. A watcher
   that logs (and messages the session) "Dolphin exited with N" would
   have cut hours off the last debugging session.
2. **Graceful controller EPIPE.** A closed pipe currently crashes the
   controller GenServer and cascades; it should latch the session into
   the same terminal state as a console disconnect.
3. **Type scene `0x28`** (boot path on both builds) instead of blind
   recovery, and record what the "4-man survival test!" CSS banner is.
4. **ExiAI + nametag suite disconnect** (open bug): the spectator link
   drops seconds into the two-port memory-card flow on the ExiAI build,
   either transport. Netplay build is unaffected. Until understood,
   nametag work needs the netplay build (windowed — it ignores the
   headless flag).
5. **Library-level cross-port sequencing.** The sequence-then-gate
   pattern lives in test orchestration today; a
   `Melee.MenuHelper.coordinate/2` (or Session-level plan) would let
   users fall into the pit of success.

### Validation

- ~~Extend the peppi differential to pre-2.2.0 files~~ — DONE
  (2026-08-16, exphil `ef35986`): the entire pre-2.2.0 corpus
  population, 9,092 replays through `Melee.SlpFile`'s manual bookends,
  compared field-by-field against peppi — **9,087 OK, 0 divergences**
  (the only 5 skips are Rust panics inside peppi's own deserializer).
  The run found and fixed two real `SlpFile` bugs (final-frame drop at
  GAME_END; duplicated-frame merge) and byte-verified one case where
  peppi fabricates data over a Slippi write-gap while this codec stays
  faithful to the raw.
- EnetBeam ↔ EnetNif cross-compat property tests over loopback (the
  NIF's `host_listen` exists for exactly this).
- A CI-optional job that runs the smoke catalog nightly against a real
  Dolphin, so live claims don't rot.
- Port 2-4 CSS coordinates are now measured; the name-entry keyboard
  grid and CONFIRM behavior are selection-index-driven and port-free,
  but have only been *exercised* per-port, not exhaustively measured.

### Speed

- Throughput is emulator-bound (~400 fps unlocked); the library is not
  the bottleneck. The send path is ~5x cheaper than the Python bridge
  (p50 6µs vs 30µs, exphil bench).
- Bench EnetBeam vs EnetNif under load before optimizing either; no
  measured gap justifies the NIF yet.
- Boot-to-CSS (~8s) dominates iteration time for menu tests. A
  persistent warm session pool (`Melee.SessionPool`) amortizes it;
  a "boot to CSS" gecko code could cut it further if one is adopted
  upstream.
- Menu navigation itself has known slack (fixed `@nametag_settle_frames`
  style waits); tightening is possible but has historically traded
  straight into flakiness — measure before touching.
