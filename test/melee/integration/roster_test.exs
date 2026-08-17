defmodule Melee.Integration.RosterTest do
  use ExUnit.Case

  @moduledoc """
  Character-select coverage beyond Fox and Falco:

    * the FULL ROSTER — all 25 CSS-pickable characters locked in on one
      port in one session, exercising every cell of the ported portrait
      grid math (and the B-press coin reclaim between picks);
    * SHEIK — the only character that isn't a portrait: MenuHelper picks
      Zelda and holds A through the load, verified all the way into the
      match;
    * FROZEN STADIUM off — `--only dolphin_stages` already runs the
      toggle path (`frozen_stadium` defaults true); this covers the
      no-toggle path. NOTE the gamestate cannot see whether the stage
      is actually frozen — transformations are invisible to the
      spectator stream — so both tests assert the navigation paths, not
      the frozen-ness itself.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_roster
  """

  alias Melee.{Enums, GameState, Match, Probe, Session}

  @moduletag :dolphin
  @moduletag :dolphin_roster
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_roster_it")

  # Every CSS portrait, by internal-id atom (sheik and nana are not
  # portraits; wireframes/giga/sandbag are not on the CSS).
  @roster ~w(
    mario fox cptfalcon dk kirby bowser link ness peach popo pikachu
    samus yoshi jigglypuff mewtwo luigi marth zelda ylink doc falco
    pichu gameandwatch ganondorf roy
  )a

  setup_all do
    path = System.get_env("MELEE_DOLPHIN_PATH")
    iso = System.get_env("MELEE_ISO_PATH")

    if path == nil or iso == nil do
      {:ok, skip: "set MELEE_DOLPHIN_PATH and MELEE_ISO_PATH"}
    else
      {:ok, path: Path.expand(path), iso: Path.expand(iso)}
    end
  end

  defp windowed?, do: System.get_env("MELEE_WINDOWED") == "1"

  test "all 25 CSS portraits lock in", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      File.rm_rf!(@home)

      probe =
        Probe.start!(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_592,
          headless: not windowed?(),
          gfx_backend: if(windowed?(), do: "OGL", else: "Null"),
          ports: [1]
        )

      try do
        fd = Enums.Stage.to_id(:final_destination)

        probe =
          Probe.navigate!(probe,
            port: 1,
            character: Enums.Character.to_id(:mario),
            stage: fd,
            timeout_frames: 8_000
          )

        started = System.monotonic_time(:millisecond)

        Enum.reduce(@roster, probe, fn char, probe ->
          opts = [port: 1, character: Enums.Character.to_id(char), stage: fd]

          probe =
            Probe.drive!(probe, &Probe.port_configured?(&1, opts), opts,
              timeout_frames: 3_000,
              describe: "#{char} to lock in"
            )

          # Fresh helper per pick, as a new Match.play would use.
          Probe.reset_helper(probe)
        end)

        elapsed = System.monotonic_time(:millisecond) - started
        IO.puts("\n[dolphin] roster: 25/25 locked in, #{elapsed}ms")
      after
        Probe.stop(probe)
      end
    end
  end

  test "Sheik: picked as Zelda, transformed by the load-time A hold", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      File.rm_rf!(@home)

      {:ok, session} = start_session(ctx, 51_591)
      on_exit(fn -> safe_stop(session) end)

      {:ok, first} =
        Match.play(session,
          p1: [character: :sheik],
          p2: [character: :falco],
          stage: :final_destination
        )

      assert GameState.in_game?(first)
      me = wait_for_character(session, first, 1, 120)

      assert me == Enums.Character.to_id(:sheik),
             "expected Sheik (#{Enums.Character.to_id(:sheik)}), got character #{me}"

      IO.puts("\n[dolphin] sheik: transformed at load")
      assert :ok = Session.stop(session)
    end
  end

  test "Frozen Stadium: the toggle provably lands, both directions", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      File.rm_rf!(@home)

      {:ok, session} = start_session(ctx, 51_590)
      on_exit(fn -> safe_stop(session) end)
      controller = Session.controller(session, 1)

      # The game's own GAME_START block records whether the stage is
      # frozen (gamestate.is_frozen_ps) — the authoritative readback
      # for MenuHelper's Z-toggle. The actual transformations start too
      # late to watch in a smoke test (none within 9,000 frames
      # measured), but the live 0x41 decode path is still asserted via
      # the baseline state broadcast Stadium emits at match start.
      #
      # ORDER MATTERS: the frozen flag PERSISTS across matches within a
      # session, and MenuHelper toggles blind (no readback exists at
      # the stage select) — found live when [true, false] left game 2
      # frozen. From a fresh session the state is known (off), so
      # false-then-true is deterministic.
      for frozen? <- [false, true] do
        {:ok, first} =
          Match.play(session,
            p1: [character: :fox, frozen_stadium: frozen?],
            p2: [character: :falco],
            stage: :pokemon_stadium
          )

        assert GameState.in_game?(first)
        assert first.stage == Enums.Stage.to_id(:pokemon_stadium)

        assert first.is_frozen_ps == frozen?,
               "asked frozen_stadium: #{frozen?}, GAME_START recorded #{first.is_frozen_ps}"

        assert %Melee.StadiumTransformation{} = first.stadium_transformation

        {:ok, _} = Match.quit(session, controller)
      end

      IO.puts("\n[dolphin] frozen_stadium: toggle verified both ways via is_frozen_ps")
      assert :ok = Session.stop(session)
    end
  end

  defp start_session(ctx, port) do
    Session.start_link(
      path: ctx.path,
      iso_path: ctx.iso,
      home: @home,
      slippi_port: port,
      headless: not windowed?(),
      gfx_backend: if(windowed?(), do: "OGL", else: "Null"),
      blocking_input: true,
      ports: [1, 2],
      console: [polling_mode: true, polling_timeout: 100]
    )
  end

  # The character byte can report Zelda for the first frames while the
  # load-time transform completes; give it a moment.
  defp wait_for_character(_session, gamestate, port, 0),
    do: gamestate.players[port] && gamestate.players[port].character

  defp wait_for_character(session, gamestate, port, tries) do
    char = gamestate.players[port] && gamestate.players[port].character

    if char == Melee.Enums.Character.to_id(:sheik) do
      char
    else
      case Session.step(session) do
        {:ok, next} -> wait_for_character(session, next, port, tries - 1)
        _ -> wait_for_character(session, gamestate, port, tries - 1)
      end
    end
  end

  defp safe_stop(session) do
    Session.stop(session)
  catch
    _, _ -> :ok
  end
end
