# libmelee_ex — handoff / resume point

Written 2026-08-05, at the end of the session that built the port. Read
this first; it is the live resume point. Everything below is verified
unless it says otherwise.

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

- `mix test`: 80 doctests, 3 properties, 201 tests, 0 failures
  (4 excluded: `:dolphin` integration tags).
- `mix credo --strict`, `mix dialyzer` (0 errors), `mix format --check`
  all clean. CI at `.github/workflows/ci.yml`.
- exphil runs entirely on this library — **the Python `melee_bridge.py`
  is out of the live-play loop.**

### What is verified, and how

| Claim | Evidence |
|---|---|
| Event codec is correct | 10,847 real replays / 12.3M frames parse (SLP 3.0.0–3.19.1); the only 2 failures are corrupt files peppi also rejects |
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
| `Melee.Console` | connect + `step/2`, frame queue, controller flush ordering |
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

## Next work (task list, in the user's chosen order)

1. **Netplay Direct as a repeatable tagged test** — `examples/netplay_direct.exs`
   works but is not a test. Use `Melee.Probe`, netplay-stable build, two
   account homes via `copy_home_from`; assert both sides reach in-game and
   own_port resolves asymmetrically. Guard with `elapsed_ms`.
2. **Differential property test vs peppi** — parse the same replays with
   `Melee.Events` and the peppi NIF, diff field-by-field across thousands
   of files (the corpus sweep only asserted no-crash/monotonic). Report
   first divergence as file+frame+field.
3. **Console robustness** — reconnect-on-disconnect, plus a supervised
   `Melee.Session` owning Dolphin + console + controllers with restart
   semantics (exphil's `MeleePort` is this, hand-wired).
4. **`Melee.SlpFile`** — feed a `.slp` through the same codec so bot code
   can be driven deterministically offline (libmelee's `slpfilestreamer`).
5. **Remaining v0.47 PORT-LATER deltas** — launcher `Settings`
   autodetection (`DolphinInfo`, ISO autodetect, `useNetplayBeta`
   tolerance), `replay_monthly_folders`, `log_types: ALL`,
   `has_user_json` guard, ExiAI detection in the version probe.
6. **Rollback semantics tests** — `skip_rollback_frames: false` must
   deliver re-simulated frames (slippi-ai depends on it); `:rollback`
   signal + blocking-input flush ordering; frame regression across games.

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
