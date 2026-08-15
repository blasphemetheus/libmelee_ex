# Getting started

This guide takes you from nothing to a bot playing a live game of Melee,
and then shows you the smoke tests that prove each capability on your
machine. It assumes you know Elixir basics and nothing about Slippi
internals.

## How the pieces fit

libmelee_ex plays Melee by doing three jobs at once:

1. **Watching.** Slippi Dolphin runs a small "spectator" server that
   broadcasts what happens in the game, frame by frame, as binary
   events. `Melee.Console` connects to it and turns the stream into one
   `Melee.GameState` struct per frame.
2. **Acting.** Dolphin can be configured to read controller input from
   a named pipe — a special file your program writes lines like
   `PRESS A` into, which Dolphin treats as a real GameCube pad.
   `Melee.Controller` speaks that protocol (with the same analog
   quantization as Python libmelee, float-for-float).
3. **Navigating menus.** Melee's menus report almost nothing over the
   spectator stream, so `Melee.MenuHelper` drives them from empirically
   measured cursor coordinates — see `docs/melee-menus.md` for how that
   sausage is made.

Everything is pure Elixir: the default network transport
(`Melee.Transport.EnetBeam`) is a BEAM-native ENet implementation, so
you do not need a Rust toolchain (see README "Building" if you want the
optional NIF transport).

## What you need

- Elixir ~> 1.18.
- A Super Smash Bros. Melee **NTSC 1.02** ISO.
- One or more Slippi Dolphin builds. They are **not interchangeable** —
  each has jobs it can and cannot do:

| Build | Get it from | Use it for | Caveats |
|---|---|---|---|
| Slippi netplay (stable) | slippi.gg launcher | Netplay Direct/Unranked, watching bot games in a window | **Ignores the headless flag — always opens a window** |
| ExiAI Ishiiruka (`dolphin-emu-headless`) | vladfi1's slippi-ssbm-asm releases | Headless local games (this is what a training loop wants) | Slippi Direct does not work on it |
| Mainline Slippi | slippi.gg | Analog input over pipes | Extracted AppImage lacks a headless Qt plugin |

Add the library as a dependency (not yet on Hex):

```elixir
{:libmelee_ex, git: "https://github.com/blasphemetheus/libmelee_ex"}
```

## Your first session

`Melee.Session` is the front door: one call launches Dolphin with the
right config, connects the console, and opens a controller pipe, all
under a supervisor that dies cleanly with Dolphin.

```elixir
{:ok, session} =
  Melee.Session.start_link(
    path: "~/.local/share/slippi/exi-ai/dolphin-emu-headless",
    iso_path: "~/isos/melee.iso",
    home: "/tmp/my_bot_home",          # a private Dolphin user dir
    headless: true,
    gfx_backend: "Null",
    ports: [1],                        # controller on GC port 1
    console: [polling_mode: true, polling_timeout: 100]
  )

controller = Melee.Session.controller(session, 1)
```

`Melee.Session` handles the setup that otherwise costs an afternoon
each: installing the gecko code that makes menus visible on the stream,
disabling memory cards so Melee never blocks on a boot dialog, writing
the pad config, and starting things in the one order that works.

## The step loop

The whole library revolves around one loop: **step the console, read
the state, set the controller.** Dolphin does not advance unless you
step, and the controller holds whatever it was last told.

```elixir
defmodule MyBot do
  def run(session, controller) do
    case Melee.Session.step(session) do
      {:ok, gamestate} ->
        act(gamestate, controller)
        run(session, controller)

      nil ->
        run(session, controller)   # polling mode: no frame ready yet

      {:error, reason} ->
        {:stopped, reason}
    end
  end

  defp act(gamestate, controller) do
    if Melee.GameState.in_game?(gamestate) do
      me = Melee.GameState.player(gamestate, 1)
      # ... your policy here. For example, hold right:
      Melee.Controller.tilt_analog(controller, :main, 1.0, 0.5)
    else
      # In menus: let MenuHelper drive (see below), or release inputs.
      Melee.Controller.release_all(controller)
    end
  end
end
```

`Melee.GameState` gives you both players' position, action state,
percent, stocks, shield, jumps, hitstun, projectiles, stage — the same
field set as Python libmelee, differential-tested against peppi over
~1.34 billion field comparisons.

Two rules that save hours:

- **"Do nothing" means `release_all/1`, not "don't write".** A
  controller latches its last input.
- **Never sleep to wait for the game.** Step the console; the frame
  stream is your clock.

## Getting through the menus

`Melee.MenuHelper.step/4` drives one port from wherever the game is
(boot screens included) to a running match:

```elixir
helper = Melee.MenuHelper.new()

helper =
  Melee.MenuHelper.step(helper, gamestate, controller,
    character: 0x01,          # internal ids: Fox = 0x01
    stage: 0x19,              # Final Destination = 0x19
    autostart: true
  )
```

Call it every frame while not in-game, keeping the returned state.
For a bot-vs-CPU match you run one helper per port and gate the start:
READY TO FIGHT comes up the instant a second port is filled, well
before the CPU level finishes configuring, and two cross-port flows
(a nametag and a CPU slider drag) must be sequenced, never
interleaved. `docs/melee-menus.md` covers those rules and every menu
trap we know; the nametag integration test is a worked two-port
example.

## Seeing it work: the smoke-test catalog

Each capability has a tagged integration test you can rerun any time to
watch it prove itself against a real Dolphin. They are excluded from
plain `mix test`; run them with `--only <tag>` and these env vars:

```sh
export MELEE_ISO_PATH=~/isos/melee.iso
# per-test build choice below
export MELEE_DOLPHIN_PATH=...
```

| Capability | Command | Build | Pass looks like |
|---|---|---|---|
| Whole stack: launch, connect, live frames | `mix test --only dolphin_session` | ExiAI headless | green in ~5-10s, no window |
| Dolphin process management | `mix test --only dolphin` (includes all of these) | per test | — |
| Nametag select, CPU config, full match start (seeded card) | `mix test --only nametag_select` | ExiAI headless | `select: ~5s`, no window, match starts with the EXPH tag and Falco at CPU 9 |
| Nametag creation from a wiped home (card provisioning + boot prompt) | `mix test --only nametag_create` | netplay (window appears; it ignores headless, and only it shows the boot prompt) | `create: ~10s` and a `.gci` written |
| Slippi Direct netplay, both sides | `mix test --only netplay_direct` | netplay | two instances matchmake; ~24s |

Knobs:

- `MELEE_WINDOWED=1` — render a window (OGL) where the build allows a
  choice, so you can watch.
- `MELEE_TRANSPORT=nif` — run the same test over the Rust NIF
  transport instead of the BEAM-native default.

If a run stalls and you kill Dolphin by hand, the library survives it:
the session tears down and no emulator is leaked (a killed window shows
up as `{:error, :enet_disconnected}` / a controller `:epipe`, both of
which are handled).

## Troubleshooting

- **Session hangs in menus, zero frames.** The "Extract Menu Info"
  gecko code is missing. `Melee.Dolphin` installs it by default —
  if you launched Dolphin yourself, don't.
- **Boot hangs on a nameless screen.** A memory card with data Melee
  doesn't recognize opens "Create Game Data?". Cards are disabled by
  default; use `memory_card: :folder` if you actually want saves
  (nametags need it).
- **Fresh netplay-build home boots into a Slippi log-in screen.**
  Known; `MenuHelper`'s unknown-scene recovery backs out of it.
- **A window appears despite `headless: true`.** You're on the netplay
  AppImage; it has no headless mode. Use the ExiAI build for headless.
- **Weird failures after a crashed run.** Check for a leaked Dolphin
  (`pgrep -f Slippi`) squatting on the spectator port or controller
  pipes, and wipe the test home directory.
- **`{:error, :enet_disconnected}` right at connect.** Something else
  is bound to the spectator port — usually a second Dolphin from a
  previous run.

## Where to go next

- `docs/melee-menus.md` — the measured mechanics of driving Melee's
  menus, and how to measure a new screen yourself.
- `docs/behavior-testing.md` — what the library can make the game do,
  where its semantic edges are, and how to write a test for a specific
  in-game behavior.
- `examples/` — worked scripts, including a two-account netplay Direct
  session.
