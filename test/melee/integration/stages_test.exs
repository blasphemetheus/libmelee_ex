defmodule Melee.Integration.StagesTest do
  use ExUnit.Case

  @moduledoc """
  Stage-select coverage: every named stage target actually lands its
  stage. The coordinates were ported from Python libmelee and only
  Final Destination had ever been verified live here — this starts a
  match on all six, in one session, quitting out of each with
  `Melee.Match.quit/3` (LRAS).

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_stages
  """

  alias Melee.{Enums, GameState, Match, Session}

  @moduletag :dolphin
  @moduletag :dolphin_stages
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_stages_it")

  # The six tournament-legal stages — the named targets in
  # MenuHelper's stage-select map (random_stage excluded: its result
  # is not assertable).
  @stages [
    :battlefield,
    :final_destination,
    :dreamland,
    :pokemon_stadium,
    :yoshis_story,
    :fountain_of_dreams
  ]

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

  test "all six legal stages are reachable and land where asked", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_593,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          blocking_input: true,
          ports: [1, 2],
          console: [polling_mode: true, polling_timeout: 100]
        )

      on_exit(fn -> safe_stop(session) end)

      controller = Session.controller(session, 1)

      for stage <- @stages do
        started = System.monotonic_time(:millisecond)

        {:ok, first} =
          Match.play(session,
            p1: [character: :fox],
            p2: [character: :falco],
            stage: stage
          )

        assert GameState.in_game?(first)

        assert first.stage == Enums.Stage.to_id(stage),
               "asked for #{stage} (#{Enums.Stage.to_id(stage)}), " <>
                 "got stage id #{first.stage}"

        {:ok, after_quit} = Match.quit(session, controller)
        refute GameState.in_game?(after_quit)

        elapsed = System.monotonic_time(:millisecond) - started
        IO.puts("[dolphin] #{stage}: ok in #{elapsed}ms")
      end

      assert :ok = Session.stop(session)
    end
  end

  defp safe_stop(session) do
    Session.stop(session)
  catch
    _, _ -> :ok
  end
end
