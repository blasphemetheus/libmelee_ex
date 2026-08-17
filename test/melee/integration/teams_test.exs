defmodule Melee.Integration.TeamsTest do
  use ExUnit.Case

  @moduledoc """
  Doubles: a bot-driven 2v2, from cold boot to a running Team Battle.

  Encodes the teams mechanics measured live on 2026-08-17 (windowed
  discovery with the user spotting, then headless verification — see
  docs/melee-menus.md "Team Battle"):

    * the MODE TOGGLE is the MELEE / TEAM BATTLE text at ~(-29.7, 24.2):
      one A per flip, the hand must be EMPTY (a held token gets placed
      instead of pressing), and the press needs a settle after arrival
      or it is swallowed;
    * every port defaults to RED, so a fresh teams match cannot start
      (`ready_to_start` stays false — the headless teams-valid signal);
    * each port's TEAM COLOR CHIP sits right of its HMN tab at
      `(-25.7 + 15.82*(N-1), -1.9)` and cycles RED -> BLUE -> GREEN per
      (settled, empty-hand) A press;
    * GAME_START is the readback: `is_teams` and per-player `team_id`
      (0 red, 1 blue, 2 green).

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_teams
  """

  alias Melee.{Enums, GameState, Probe}

  @moduletag :dolphin
  @moduletag :dolphin_teams
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_teams_it")

  @mode_toggle {-29.7, 24.2}
  @chip_x_base -25.7
  @chip_y -1.9
  @panel_spacing 15.82

  @red 0
  @blue 1

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

  test "a 2v2 Team Battle starts with the asked-for teams", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      probe =
        Probe.start!(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_583,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          blocking_input: true,
          ports: [1, 2, 3, 4]
        )

      chars = %{1 => :fox, 2 => :falco, 3 => :marth, 4 => :peach}
      ids = Map.new(chars, fn {p, c} -> {p, Enums.Character.to_id(c)} end)
      fd = Enums.Stage.to_id(:final_destination)

      try do
        probe =
          Probe.navigate!(probe, port: 1, character: ids[1], stage: fd, timeout_frames: 8_000)

        # Pick all four characters, waiting for each COIN to be placed —
        # hover alone leaves the token in hand, and a held token cannot
        # press the mode toggle or a color chip.
        probe =
          Enum.reduce([1, 2, 3, 4], probe, fn port, probe ->
            opts = [port: port, character: ids[port], stage: fd]

            probe =
              Probe.drive!(
                probe,
                fn probe ->
                  p = Probe.gamestate(probe).players[port]
                  p != nil and p.character == ids[port] and p.coin_down
                end,
                opts,
                timeout_frames: 4_000,
                describe: "port #{port} pick"
              )

            Probe.reset_helper(probe, port)
          end)

        # Team Battle on.
        {tx, ty} = @mode_toggle
        probe = Probe.goto!(probe, tx, ty, port: 1, tolerance: 0.4, timeout_frames: 900)
        probe = Probe.idle!(probe, 60)
        probe = Probe.tap!(probe, :a, port: 1)
        probe = Probe.idle!(probe, 30)

        # All ports default red: the match must NOT be startable yet.
        refute Probe.gamestate(probe).ready_to_start,
               "teams mode with all-red teams reported ready_to_start"

        # Ports 3 and 4 to blue (one settled A on each chip).
        probe =
          Enum.reduce([3, 4], probe, fn port, probe ->
            x = @chip_x_base + @panel_spacing * (port - 1)

            probe =
              Probe.goto!(probe, x, @chip_y, port: port, tolerance: 0.4, timeout_frames: 900)

            probe = Probe.idle!(probe, 60)
            probe = Probe.tap!(probe, :a, port: port)
            Probe.idle!(probe, 30)
          end)

        # Valid teams: the READY banner is the headless readback.
        assert Probe.gamestate(probe).ready_to_start,
               "2v2 red/red vs blue/blue should be startable"

        # Start and verify from the game's own record.
        probe =
          Probe.drive!(
            probe,
            &Probe.at_menu?(&1, :in_game),
            fn _ -> [[port: 1, character: ids[1], stage: fd, autostart: true]] end,
            timeout_frames: 8_000,
            describe: "the teams match to start"
          )

        gs = Probe.gamestate(probe)
        assert GameState.in_game?(gs)
        assert gs.is_teams

        teams = Map.new(1..4, fn p -> {p, gs.players[p].team_id} end)
        assert teams == %{1 => @red, 2 => @red, 3 => @blue, 4 => @blue}

        IO.puts("\n[dolphin] teams: 2v2 started, teams=#{inspect(teams)}")
      after
        Probe.stop(probe)
      end
    end
  end
end
