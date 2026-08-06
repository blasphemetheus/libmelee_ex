# libmelee_ex

An Elixir port of [libmelee](https://github.com/vladfi1/libmelee) — the API
for writing Super Smash Bros. Melee AIs that work with Slippi Online.

Tracks the semantics of **vladfi1's actively maintained fork** (the
original `altf4/libmelee` was archived in January 2026). The parity
target is the fork at ~v0.47; binary parse paths are golden-tested
against real `.slp` streams and Python libmelee's numeric output.

## Status

v1 = the **minimal live-play core**:

| Piece | Module | Status |
|---|---|---|
| Game snapshot structs | `Melee.GameState`, `Melee.PlayerState`, `Melee.Projectile` | done |
| Enums (Character, Action, Stage, ...) | `Melee.Enums.*` | done |
| Stage geometry constants | `Melee.Stages` | done |
| Slippi binary event decoder | `Melee.Events` | done |
| Spectator protocol codec | `Melee.Slippstream` | done |
| Live console (connect + step) | `Melee.Console` | done |
| Controller over named pipe | `Melee.Controller` | done |
| Pad/ini setup helper | `Melee.DolphinConfig` | done |
| ENet transport (Rust NIF) | `Melee.Transport.EnetNif` | done |
| ENet transport (BEAM-native) | `Melee.Transport.EnetBeam` | done |
| Dolphin process management | `Melee.Dolphin` | done |
| Menu navigation | `Melee.MenuHelper` | done |

Validated end-to-end: a full headless game (menus → character/stage
select → live frames with inputs) driven entirely from Elixir, and
[exphil](https://github.com/blasphemetheus/exphil)'s bridge runs on this
library with its Python bridge deleted from the loop.

Out of scope: replay-file streaming — for `.slp` replay *parsing* at
scale, use a [peppi](https://github.com/hohav/peppi)-based parser
instead; the live event decoder here is for the spectator stream.

## Usage

```elixir
# Dolphin (Slippi netplay or ExiAI build) already running with the
# spectator server on the default port.
{:ok, console} = Melee.Console.start_link([])

# Optional: a controller on port 1 (needs pad config once, then a
# Dolphin restart)
{:ok, pipe} = Melee.DolphinConfig.setup_controller(dolphin_home, 1)
{:ok, controller} = Melee.Controller.start_link(pipe_path: pipe)

:ok = Melee.Console.connect(console)
:ok = Melee.Console.register_controller(console, controller)
:ok = Melee.Controller.connect(controller)   # blocks until Dolphin attaches

# The step loop: one GameState per frame at 60 fps
{:ok, gamestate} = Melee.Console.step(console)

if Melee.GameState.in_game?(gamestate) do
  player = Melee.GameState.player(gamestate, 1)
  Melee.Controller.tilt_analog(controller, :main, 1.0, 0.5)
  Melee.Controller.press_button(controller, :b)
end
# inputs are committed by the next step's flush
```

Values mirror libmelee: enum-valued fields hold raw integers
(`Melee.Enums.Action.from_id/1` etc. convert to atoms), sticks are
`{x, y}` in `[0, 1]` with `0.5` neutral, analog inputs are quantized by
default so what you send matches what `step` reports back.

### Differences from Python libmelee

* Event bytes left over after a frame bookend are **buffered**, not
  dropped-with-a-warning.
* Rollback-skipped frames surface as a distinct signal internally, so
  blocking-input flushes are exact rather than incidental.
* Everything is process-based: `Console` and each `Controller` are
  supervisable GenServers; transports are swappable behind
  `Melee.Transport`.

## Building

Rust is required for the ENet NIF. On NixOS:

```sh
nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc --command mix test
# or: devenv shell -- mix test
```

## Testing

```sh
mix test                    # unit + property + golden replay tests
mix test --only dolphin     # integration vs a live Slippi Dolphin
```

Live menu work (nametags, new screens) is driven by `Melee.Probe` in
`test/support` — a frame loop with cursor steering, button pulses and
tracing. See `examples/nametag_session.exs` for a worked session, and
[Driving Melee's menus](docs/melee-menus.md) for the measured mechanics
behind `Melee.MenuHelper`.

The golden tests parse a real `.slp` replay (byte-identical framing to
the live spectator stream) and assert monotonic frames, sane physics,
and chunked-delivery equivalence. Controller quantization is asserted
against Python libmelee's exact float outputs.

## License

LGPL-3.0, same as libmelee.
