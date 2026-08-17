defmodule Melee.Integration.TeamsTest do
  use ExUnit.Case

  @moduledoc """
  Doubles through the PUBLIC API: `Melee.Match.play/2` with
  `teams: true` takes a cold boot to a running 2v2 Team Battle — picks,
  mode toggle, color chips, ready-gating, START — and the game's own
  GAME_START record proves it (`is_teams`, per-player `team_id`).

  The underlying mechanics were measured live on 2026-08-17 (windowed
  discovery with the user spotting) and are documented in
  docs/melee-menus.md "Team Battle"; `Melee.Cursor` carries the
  promoted steering/settled-press primitives.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_teams
  """

  alias Melee.{Enums, GameState, Match, Session}

  @moduletag :dolphin
  @moduletag :dolphin_teams
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_teams_it")

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

  test "Match.play(teams: true) starts a 2v2 with the asked-for teams", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_583,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          blocking_input: true,
          ports: [1, 2, 3, 4],
          console: [polling_mode: true, polling_timeout: 100]
        )

      on_exit(fn -> safe_stop(session) end)

      {:ok, first} =
        Match.play(session,
          teams: true,
          p1: [character: :fox],
          p2: [character: :falco],
          p3: [character: :marth, team: :blue],
          p4: [character: :peach, team: :blue],
          stage: :final_destination
        )

      assert GameState.in_game?(first)
      assert first.is_teams

      teams = Map.new(1..4, fn p -> {p, first.players[p].team_id} end)

      assert teams == %{
               1 => Enums.Team.to_id(:red),
               2 => Enums.Team.to_id(:red),
               3 => Enums.Team.to_id(:blue),
               4 => Enums.Team.to_id(:blue)
             }

      IO.puts("\n[dolphin] teams: 2v2 via Match.play, teams=#{inspect(teams)}")
      assert :ok = Session.stop(session)
    end
  end

  defmodule DoublesBot do
    use Melee.Bot

    # Holds right; after frame 240 records what it saw and quits.
    @impl true
    def act(_me, gamestate, controller) do
      if gamestate.frame > 240 do
        teams = Map.new(gamestate.players, fn {p, pl} -> {p, pl.team_id} end)
        Agent.update(:doubles_bot_probe, fn _ -> {gamestate.is_teams, teams} end)
        :quit
      else
        Melee.Controller.tilt_analog(controller, :main, 1.0, 0.5)
      end
    end
  end

  test "Bot.run plays doubles and can quit the episode", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      File.rm_rf!(@home)
      windowed? = System.get_env("MELEE_WINDOWED") == "1"
      {:ok, _} = Agent.start_link(fn -> nil end, name: :doubles_bot_probe)

      result =
        Melee.Bot.run(DoublesBot,
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_582,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          console: [polling_mode: true, polling_timeout: 100],
          teams: true,
          character: :fox,
          team: :red,
          p2: [character: :falco, team: :red],
          p3: [character: :marth, team: :blue],
          p4: [character: :peach, team: :blue],
          stage: :final_destination
        )

      assert {:ok, %{frames: frames, last: last}} = result
      assert frames > 240
      refute Melee.GameState.in_game?(last)

      assert {true, teams} = Agent.get(:doubles_bot_probe, & &1)

      assert teams == %{
               1 => Enums.Team.to_id(:red),
               2 => Enums.Team.to_id(:red),
               3 => Enums.Team.to_id(:blue),
               4 => Enums.Team.to_id(:blue)
             }

      IO.puts("\n[dolphin] bot doubles: quit at frame #{frames}, teams=#{inspect(teams)}")
    end
  end

  defp safe_stop(session) do
    Session.stop(session)
  catch
    _, _ -> :ok
  end
end
