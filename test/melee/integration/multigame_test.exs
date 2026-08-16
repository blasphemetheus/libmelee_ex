defmodule Melee.Integration.MultigameTest do
  use ExUnit.Case

  @moduledoc """
  What a training loop actually does all day: many games, one emulator.

  Three full games back-to-back in a single `Melee.Session` —
  `Melee.Match.play/2` navigates from cold boot the first time and from
  the postgame scores screen the other two, the bot burns its stocks,
  and Dolphin is never relaunched (asserted by os pid). Per-game
  overhead after the first is menu time alone.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_multigame
  """

  alias Melee.{Controller, GameState, Match, Session}

  @moduletag :dolphin
  @moduletag :dolphin_multigame
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_multigame_it")
  @games 3

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

  test "#{@games} games back-to-back in one Dolphin session", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_594,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          blocking_input: true,
          ports: [1, 2],
          console: [polling_mode: true, polling_timeout: 100]
        )

      on_exit(fn -> safe_stop(session) end)

      os_pid = Session.dolphin(session).os_pid
      controller = Session.controller(session, 1)

      results =
        for game <- 1..@games do
          menu_start = System.monotonic_time(:millisecond)

          {:ok, first} =
            Match.play(session,
              p1: [character: :fox],
              p2: [character: :falco],
              stage: :final_destination
            )

          menu_ms = System.monotonic_time(:millisecond) - menu_start
          assert GameState.in_game?(first)

          frames = burn_stocks(session, controller, first, 0)

          IO.puts("[dolphin] game #{game}: menus=#{menu_ms}ms frames=#{frames}")
          {menu_ms, frames}
        end

      # Same emulator the whole way through.
      assert Session.dolphin(session).os_pid == os_pid

      # Every game genuinely played out (4 self-destructs each measure
      # ~1000 frames), and the second game onward paid only menu time.
      for {_menu_ms, frames} <- results, do: assert(frames > 800)

      [{first_menus, _} | rest] = results

      for {menu_ms, _} <- rest do
        assert menu_ms < first_menus + 10_000,
               "post-game menus took #{menu_ms}ms vs #{first_menus}ms with a cold boot"
      end

      assert :ok = Session.stop(session)
    end
  end

  # Hold right: Fox dashes off the right edge until the game ends.
  defp burn_stocks(session, controller, gamestate, frames) do
    if GameState.in_game?(gamestate) do
      Controller.tilt_analog(controller, :main, 1.0, 0.5)

      case Session.step(session) do
        {:ok, next} -> burn_stocks(session, controller, next, frames + 1)
        nil -> burn_stocks(session, controller, gamestate, frames)
      end
    else
      Controller.release_all(controller)
      frames
    end
  end

  defp safe_stop(session) do
    Session.stop(session)
  catch
    _, _ -> :ok
  end
end
