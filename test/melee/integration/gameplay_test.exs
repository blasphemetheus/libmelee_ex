defmodule Melee.Integration.GameplayTest do
  use ExUnit.Case

  @moduledoc """
  The capability every other test stops short of: inputs affect a real
  running match. Boots a headless game (Fox vs a level-1 CPU on FD),
  then holds the stick and asserts the character actually moves the way
  it was told to.

  Runs windowless on the ExiAI build:

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_gameplay
  """

  alias Melee.{Controller, Enums, GameState, Probe}

  @moduletag :dolphin
  @moduletag :dolphin_gameplay
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_gameplay_it")

  # Wall-clock floor against a vacuous pass. Deliberately loose: probe
  # elapsed excludes the Dolphin boot wait, and an unlocked headless
  # ExiAI legitimately does menus + 80 frames of play in ~1.3s (a 2s
  # floor flaked). The frame-clock and movement assertions are the real
  # vacuity guards; this only catches "never drove anything at all".
  @min_run_ms 500

  setup_all do
    path = System.get_env("MELEE_DOLPHIN_PATH")
    iso = System.get_env("MELEE_ISO_PATH")

    if path == nil or iso == nil do
      {:ok, skip: "set MELEE_DOLPHIN_PATH and MELEE_ISO_PATH"}
    else
      File.rm_rf!(@home)
      {:ok, path: Path.expand(path), iso: Path.expand(iso)}
    end
  end

  test "holding the stick moves the character on the stage", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      probe =
        Probe.start!(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_598,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          # Load-bearing on the ExiAI build: with blocking pipes OFF,
          # menus obey the controller but IN-GAME input is ignored
          # entirely (Fox stood in Wait through 60 frames of held
          # right, then just got comboed by the CPU — found live
          # writing this test).
          blocking_input: true,
          ports: [1, 2]
        )

      bot_opts = [
        port: 1,
        character: Enums.Character.to_id(:fox),
        stage: Enums.Stage.to_id(:final_destination)
      ]

      cpu_opts = [
        port: 2,
        character: Enums.Character.to_id(:falco),
        stage: Enums.Stage.to_id(:final_destination),
        cpu_level: 1
      ]

      try do
        probe =
          Probe.drive!(
            probe,
            &Probe.at_menu?(&1, :in_game),
            fn probe ->
              [
                bot_opts ++ [autostart: Probe.autostart?(probe, [cpu_opts])],
                cpu_opts
              ]
            end,
            timeout_frames: 20_000,
            describe: "the match to start"
          )

        # Let the match settle out of the entry animation.
        probe = Probe.idle!(probe, 60)

        x_of = fn probe -> Probe.gamestate(probe).players[1].position.x end
        frame_of = fn probe -> Probe.gamestate(probe).frame end

        # Hold hard right for ~40 frames: Fox must travel right. Not
        # longer — a full dash covers ~40 units in 30 frames, and FD's
        # edge is at ±85.57; a longer hold ran him clean off the stage
        # to his death when this test was first calibrated live. 3.0 is
        # far above jitter but survives a knock from the CPU.
        controller = probe.controllers[1]
        x0 = x_of.(probe)
        f0 = frame_of.(probe)

        probe =
          Probe.advance!(probe, 40, fn probe ->
            Controller.tilt_analog(controller, :main, 1.0, 0.5)
            probe
          end)

        x1 = x_of.(probe)
        assert x1 > x0 + 3.0, "held right for 40 steps, x went #{x0} -> #{x1}"

        # And back: the input is live, not a one-off.
        probe =
          Probe.advance!(probe, 40, fn probe ->
            Controller.tilt_analog(controller, :main, 0.0, 0.5)
            probe
          end)

        x2 = x_of.(probe)
        assert x2 < x1 - 3.0, "held left for 40 steps, x went #{x1} -> #{x2}"

        # The frame clock advanced while we did it — this was a live
        # game, not a stale snapshot re-read.
        assert frame_of.(probe) > f0 + 60

        gs = Probe.gamestate(probe)
        assert GameState.in_game?(gs)

        assert Probe.elapsed_ms(probe) > @min_run_ms,
               "expected a real boot-and-play, finished in #{Probe.elapsed_ms(probe)}ms"

        IO.puts(
          "\n[dolphin] gameplay: #{Probe.elapsed_ms(probe)}ms steps=#{probe.frames} " <>
            "x #{Float.round(x0, 1)} -> #{Float.round(x1, 1)} -> #{Float.round(x2, 1)}"
        )
      after
        Probe.stop(probe)
      end
    end
  end
end
