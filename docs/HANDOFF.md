# libmelee_ex — handoff / resume point

Written 2026-08-05, at the end of the session that built the port. Read
this first; it is the live resume point. Everything below is verified
unless it says otherwise.

## Addendum 2026-08-14

- **CSS coordinates measured live for ports 2-4** (`Melee.Probe`
  sessions, netplay windowed). Headline: the name box is **15.4**-spaced
  (slider pitch), not 15.82; pinned tag-list columns at exactly
  `-25.2 + 15.4*(N-1)`. Two new traps documented in `melee-menus.md`:
  a CSS panel is inert (N/A, `controller_status` 3) until the port
  locks a character; CSS fields stop updating past the CSS, so
  cross-port gates may only bite at the CSS.
- **Elixir-native by default:** `Melee.Transport.EnetBeam` is the
  default transport; the Rustler crate compiles only with
  `MELEE_BUILD_ENET_NIF=1` (prebuilt priv .so loads otherwise). Plain
  `mix test` needs no Rust.
- **Nametag select test fixed and live-verified** (create 8.1s,
  select 10.6s): the nametag flow must be sequenced after CPU config
  (keyboard interruption yanked the port-2 hand off the slider,
  9 became 8), and its gate must apply at the CSS only. `Probe.stop/1`
  is crash-tolerant now (a killed Dolphin no longer leaks the emulator).
- **Open bug (narrowed):** the ExiAI nametag failure is NOT the
  transport (both fail identically), NOT Dolphin dying (it stays
  alive), and NOT the CSS (tag list opens fine there, verified by
  probe). Root cause: on ExiAI the GCI-folder card never gets Melee
  save data — boot skips the "Create Game Data?" prompt — so the
  create flow completes vacuously and nothing persists; the
  intermittent disconnect is secondary. Next: pre-seed the card with a
  known-good `.gci`. Until then nametag work needs the netplay build
  (which ignores the headless flag and always opens a window).
- **Fixed since:** Dolphin's death is now visible
  (`Melee.Dolphin.watch/2`, stderr captured, output tail in the exit
  log; `Melee.Session` logs the tail too); a dead controller pipe
  latches gracefully instead of crash-cascading (`flush/1` returns
  `{:error, {:pipe_closed, reason}}`); boot scene `0x28` is typed
  `:boot_splash` and waited out (it auto-advances; A-pressing it was
  how runs wandered into Online Play).
- **Docs:** `docs/getting-started.md` (with smoke-test catalog) and
  `docs/behavior-testing.md` (capability catalog, semantic edges,
  improvement roadmap) added and wired into ex_doc.

## What this is

An Elixir port of [libmelee](https://github.com/vladfi1/libmelee), the
API for writing Super Smash Bros. Melee AIs that work with Slippi.
Repo: `github.com/blasphemetheus/libmelee_ex` (public). Consumed by
[exphil](https://github.com/blasphemetheus/exphil) via a path dep
(sibling checkout) — the same pattern edifice uses.

**Parity target: vladfi1's fork (~v0.47).** Upstream `altf4/libmelee`
was archived January 2026. A full v0.43→v0.47 audit found **zero
wire-format changes**, so the port's event/protocol layer is current by
construction.

## State

- `mix test`: 94 doctests, 3 properties, 281 tests, 0 failures
  (7 excluded: `:dolphin` integration tags).
- `mix credo --strict`, `mix dialyzer` (0 errors), `mix format --check`
  all clean. CI at `.github/workflows/ci.yml`.
- exphil runs entirely on this library — **the Python `melee_bridge.py`
  is out of the live-play loop.**

### What is verified, and how

| Claim | Evidence |
|---|---|
| Event codec is correct | **Differential vs peppi**: 2,625 replays, 19.1M frames, ~1.34 **billion** field comparisons, zero divergences (34 fields/player-frame). Plus a no-crash sweep over 10,847 replays |
| Bridge matches Python exactly | `exphil/scripts/parity_harness.exs`: same input schedule through both bridges, 1800 frames, **zero field mismatches** (max float delta 3e-8) |
| Live play works | Production policy `ms_g10b_human` played a full 8-min game through the native bridge: 28,924 frames to GAME_END, 1080 shine entries (~134/min) |
| Both transports work live | `mix test --only dolphin` passes over `EnetNif` and `EnetBeam` against real Dolphin |
| Netplay Direct works | Two accounts, real matchmaking, 600 frames/side, own_port correctly resolved the *asymmetric* assignment (EXPH#288→2, DBTD#411→1) |
| Nametag works | `mix test --only dolphin_nametag` from a wiped home: create 8236ms (90KB save written), select 11043ms with `nametag == "EXPH"` from GAME_START |
| Controller math matches Python | Analog quantization asserted float-exact vs Python libmelee, including banker's rounding |

## Environment (NixOS, host `nixos_slanka`)

```sh
# libmelee_ex — Rust is needed for the ENet NIF
cd ~/git/libmelee_ex
nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc --command mix test

# exphil — MUST be inside devenv (EDIFICE_LOCAL_NX, make, CUDA)
cd ~/git/exphil
devenv shell -- bash -c "EXPHIL_SKIP_NIF_COMPILE=1 mix test"
```

- **Never run bare `mix deps.get` in exphil** — it swaps the local
  nx/exla forks for hex packages.
- `EXPHIL_SKIP_NIF_COMPILE=1` is required in exphil: the `ethnum` crate
  fails under rustc 1.97 (documented in `peppi.ex`); the prebuilt `.so`
  is used instead.
- Integration tests need `MELEE_DOLPHIN_PATH` and `MELEE_ISO_PATH`.
  ISO: `/home/blewf/isos/melee.iso`.

### Dolphin builds — they are not interchangeable

| Build | Path | Use for |
|---|---|---|
| netplay-stable | `~/.local/share/slippi/netplay/Slippi_Online-x86_64.AppImage` | **Netplay Direct** (the only one where it works), windowed menu work |
| ExiAI Ishiiruka | `~/.local/share/slippi/exi-ai/dolphin-emu-headless` | headless local games, EXI inputs |
| mainline | `~/.local/share/slippi/mainline/dolphin-emu-mainline` | analog-through-pipes; its extracted AppImage lacks a headless Qt plugin |

**Slippi Direct does NOT work on the ExiAI build** — verified against a
Python libmelee oracle that froze at the identical spot. Use
netplay-stable with `gfx_backend: "Null"` (or `"OGL"` to watch).

### Hard-won Dolphin gotchas

- **Menu events require gecko codes.** The `0x3E` menu event only exists
  when libmelee's `GALE01r2.ini` "Extract Menu Info" code is installed
  (`Melee.Dolphin` does this by default). Without it a session hangs
  frameless in menus.
- **Memory cards hang boot.** A card whose data Melee doesn't recognize
  opens "Create Game Data?", a nameless scene no navigation answers.
  `Melee.Dolphin` disables cards by default; `memory_card: :folder`
  provisions one properly. `memory_card: true` only *preserves* existing
  config — it does not plug a card in (this silently lost the first
  nametag).
- Spectator config keys differ by flavor: Ishiiruka `[Core] Slippi*`
  vs mainline `[Slippi]`.

## Design conventions (follow these)

- **Raw integer wire values in structs** — internal ids, not atoms
  (Fox = `0x01`, FD = `0x19`). `Melee.Enums.*` convert for readability.
  Buttons are atoms (`:a`, `:main`). Getting external vs internal stage
  ids confused cost real debugging time.
- **HtDP design recipe** (the user's standing preference): data
  definitions → `@spec` + purpose `@doc` → worked examples (doctests) →
  template → definition → tests. Write the examples *before* the code —
  doing it backwards produced a wrong doctest and a false property.
- Lots of tests, and prefer tests that can't pass vacuously: golden
  values generated from the Python implementation, timing/frame guards
  on live tests, differential comparison over assertion-by-eyeball.

## Module map

| Module | Role |
|---|---|
| `Melee.Console` | connect + `step/2`, frame queue, controller flush ordering, opt-in reconnect |
| `Melee.Session` | supervised Dolphin + console + controllers, correct startup order |
| `Melee.Events` (+ `.Menu`) | pure Slippi binary decoder — the heart |
| `Melee.Slippstream` | spectator JSON message codec |
| `Melee.Controller` | named-pipe protocol + analog quantization |
| `Melee.MenuHelper` | menu navigation, CPU config, direct codes, **nametags** |
| `Melee.Dolphin` / `.DolphinConfig` | process + user-dir/config management |
| `Melee.Transport{,.EnetNif,.EnetBeam}` | swappable ENet (Rust NIF / pure BEAM) |
| `Melee.GameState`/`PlayerState`/`Projectile` | per-frame snapshot |
| `Melee.FrameData` | attack/hitbox/physics queries (framedata.py port) |
| `Melee.Probe` (test/support) | live-driver harness for menu work |

Docs: `docs/melee-menus.md` (measured menu mechanics), `README.md`.

### Replays older than v2.2.0 (handled by Melee.SlpFile)

`Melee.Events` completes a frame on FRAME_BOOKEND (`0x3C`), which Slippi
added in replay **v2.2.0** — same as libmelee. Older replays parse to a
clean `:game_end` with **zero frames**: silently empty, not an error.
That is ~91% of the huggingface corpus (9,092 of 9,995). Irrelevant for
live play (the spectator stream is always modern) but it means this
codec alone is **not** a bulk-ingestion path for old replays — but
`Melee.SlpFile` handles them via libmelee-style manual bookends (400/400
 verified), and peppi remains the bulk parser. `ExPhil.Data.Parity.comparable?/1`
 screens for the raw-codec case.

Note this also means an early "10,847 replays parsed" sweep was weaker
evidence than it looked: many of those files contributed no frames. The
peppi differential is the real correctness evidence.

## Verification lessons (do not relearn these)

1. **Verify a commit in a worktree, never a working tree an agent is
   editing.** I declared the nametag branch broken after testing a
   mid-flight tree; the fixes were already in the commit. `git worktree
   add <tmp> <sha>` and test there.
2. **`Melee.Probe` step counts are console steps, not emulated frames** —
   polling coalesces them. Use `Probe.elapsed_ms/1` for timing guards.
   (231 "frames" was 8.2 real seconds.)
3. Live "it worked, I saw it" reports need independent reproduction
   before merging; unit-test claims do not.

## Fixed: decoder crash on a bad port byte

`mix test --seed 777` used to fail the "parser never crashes garbage"
property — `pre_frame`/`post_frame` read the port from a `u8` and index
4-slot metadata tuples, so a corrupt stream raised
`:erlang.element(186, {1, 2, 0, 0})` and would have taken a live console
down mid-game. Fixed by dropping events with a port outside `1..4`, with
a regression test. A good advertisement for keeping the fuzz property.

## Next work

**All six queued items are done** (see below). Fresh ideas, roughly by
value: publish to Hex + HexDocs; extend the peppi differential to
pre-2.2.0 files now that `Melee.SlpFile` can read them; port `MenuHelper`
coordinate measurement to ports 2-4 (only port 1 was measured live — see
`docs/melee-menus.md`); a `Melee.Session`-based rewrite of exphil's
`MeleePort` internals; and fixing the exphil peppi NIF character-id bug
(Roy -> -1) once the rustc/ethnum build issue is resolved.

### Completed queue (for history)

1. ~~**Netplay Direct as a repeatable tagged test**~~ — DONE
   (`test/melee/integration/netplay_direct_test.exs`, `--only
   netplay_direct`). Passed live: A=EXPH#288 own_port=2, B=DBTD#411
   own_port=1, 23.9s.
2. ~~**Differential property test vs peppi**~~ — DONE (exphil `test/exphil/data/events_peppi_parity_test.exs`, `ExPhil.Data.Parity`): 2,625 replays / 1.34B comparisons / zero divergences.
3. ~~**Console robustness**~~ — DONE. `Melee.Console` takes an opt-in
   `reconnect:` policy (default `false` keeps the terminal
   `EnetDisconnected` behavior exphil depends on); a reconnect resets the
   `Melee.Events` parser and drops queued frames because it is a NEW
   stream. `Melee.Session` (`lib/melee/session.ex`) owns Dolphin +
   console + controllers with the startup order that took live debugging
   to find, restarts crashed controllers, and dies with Dolphin.
4. ~~**`Melee.SlpFile`**~~ — DONE (`8054bb3`): streams replays through the live codec, and manual bookends unlock pre-2.2.0 files (400/400 old replays now parse).
5. ~~**Remaining v0.47 PORT-LATER deltas**~~ — DONE. `Melee.Dolphin.Info`
   reads `~/.config/Slippi Launcher/Settings` (tolerant `useNetplayBeta`,
   ISO nulled when missing) and `prepare_home/1` falls back to it for
   `:path`/`:iso_path` — never fatally, `autodetect: false` opts out.
   `Melee.Dolphin.Version` + `Melee.Dolphin.version/1` shell out to
   `<exe> --version` and tell netplay from ExiAI on both flavors (all
   three local builds verified). Plus `:replay_monthly_folders`,
   `:log_types`/`:log_level` (Logger.ini, `"ALL"` → all 58 types, written
   only when asked for), `user.json` auto-copy with `dolphin.user_json?`,
   and a `MenuHelper.step/4` `:user_json?` flag that refuses a connect
   code without one (default `true`, so it is opt-in).
6. ~~**Rollback semantics tests**~~ — DONE (`test/melee/rollback_test.exs`): both modes, multi-frame rollback windows, the blocking-input flush obligation, and the new-game frame-clock reset.

## exphil side (for the other session)

- `ExPhil.Bridge.MeleePort` keeps its old public API
  (`init_console`/`step`/`send_controller`/`ping`/`stop`, polling and
  `:no_frame`, postgame protocol, dummy modes, frame-delay queue) and now
  drives libmelee_ex directly. Callers were unchanged.
- `ExPhil.Bridge.ActionQueue` is the ported frame-delay queue.
- `ExPhil.Replay.Stamp` + `mix exphil.stamp_replays <dir> --tag exph
  --port 1` writes `names.netplay` into `.slp` metadata so bot games are
  identifiable in a corpus (local games record no names). Verified: a
  stamped replay still parses byte-identically under peppi *and*
  libmelee_ex.
- Bot games can also carry the in-game nametag "EXPH" (see above); the
  card holding it lives at `~/.config/SlippiOnline-nametag`.
- `scripts/parity_harness.exs` and `scripts/bridge_latency_bench.exs`
  compare native vs Python. Latency: throughput is identical (~400 fps,
  emulator-bound) but the send path is ~5x cheaper natively (p50 6µs vs
  30µs).
