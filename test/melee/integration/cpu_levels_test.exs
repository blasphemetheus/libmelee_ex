defmodule Melee.Integration.CpuLevelsTest do
  use ExUnit.Case

  @moduledoc """
  The CPU slider across its whole range: levels 1 through 9 configured
  in ascending order (rightward drags), then back down to 3 (a leftward
  drag). Level 9 is the historically cursed one — Python's flat 0.15
  drag sat inside the stick deadzone and stalled at 8 forever; the
  feedback controller with the every-other-frame fine tilt is what
  fixed it, and this pins the whole range.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_cpu
  """

  alias Melee.{Enums, Probe}

  @moduletag :dolphin
  @moduletag :dolphin_cpu
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_cpu_levels_it")

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

  test "levels 1..9 ascending, then 3 descending, all land exactly", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      probe =
        Probe.start!(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_584,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          ports: [1, 2]
        )

      try do
        fox = Enums.Character.to_id(:fox)
        falco = Enums.Character.to_id(:falco)
        fd = Enums.Stage.to_id(:final_destination)

        probe = Probe.navigate!(probe, port: 1, character: fox, stage: fd, timeout_frames: 8_000)
        started = System.monotonic_time(:millisecond)

        Enum.reduce(Enum.to_list(1..9) ++ [3], probe, fn level, probe ->
          opts = [port: 2, character: falco, stage: fd, cpu_level: level]

          probe =
            Probe.drive!(probe, &Probe.port_configured?(&1, opts), opts,
              timeout_frames: 4_000,
              describe: "cpu level #{level}"
            )

          assert Probe.gamestate(probe).players[2].cpu_level == level
          Probe.reset_helper(probe, 2)
        end)

        elapsed = System.monotonic_time(:millisecond) - started
        IO.puts("\n[dolphin] cpu_levels: 1..9 up and 9->3 down, #{elapsed}ms")
      after
        Probe.stop(probe)
      end
    end
  end
end
