defmodule Melee.Integration.FourPlayerTest do
  use ExUnit.Case

  @moduledoc """
  Four ports in one live match — in-game four-port frame data had never
  been asserted (only ever seen at the CSS). Also covers, in the same
  session: the `:costume` option verified in-game, and the LIVE event
  pipeline (`Session.stream/2 |> GameEvents.stream/1`) producing a
  `:stock_lost` while the game runs.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_4p
  """

  alias Melee.{Controller, Enums, GameEvents, GameState, Match, Session}

  @moduletag :dolphin
  @moduletag :dolphin_4p
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_4p_it")

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

  test "four ports of live frame data, a costume, and live events", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_585,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          blocking_input: true,
          ports: [1, 2, 3, 4],
          console: [polling_mode: true, polling_timeout: 100]
        )

      on_exit(fn -> safe_stop(session) end)

      {:ok, first} =
        Match.play(session,
          p1: [character: :fox, costume: 2],
          p2: [character: :falco],
          p3: [character: :marth],
          p4: [character: :peach],
          stage: :final_destination
        )

      assert GameState.in_game?(first)

      # All four bodies, four stocks each, the right characters, and
      # port 1 wearing the asked-for costume.
      assert map_size(first.players) == 4

      expected = %{1 => :fox, 2 => :falco, 3 => :marth, 4 => :peach}

      for {port, char} <- expected do
        player = first.players[port]
        assert player, "port #{port} missing from the first in-game frame"
        assert player.character == Enums.Character.to_id(char)
        assert player.stock == 4
      end

      # Local-CSS costume selection: counted post-lock Y presses.
      assert first.players[1].costume == 2

      # Live event pipeline: hold right on port 1 (the lemming), and the
      # stream must report the self-destruct as it happens.
      controller = Session.controller(session, 1)
      Controller.tilt_analog(controller, :main, 1.0, 0.5)

      stock_lost =
        session
        |> Session.stream()
        |> GameEvents.stream()
        |> Enum.reduce_while(nil, fn
          {:stock_lost, %{port: 1} = data}, _ -> {:halt, data}
          _other, _ -> {:cont, nil}
        end)

      Controller.release_all(controller)

      assert %{kind: :sd, remaining: remaining} = stock_lost
      assert remaining == 3

      IO.puts(
        "\n[dolphin] 4p: four ports live, costume ok, live stock_lost (sd, #{remaining} left)"
      )

      {:ok, _} = Match.quit(session, controller)
      assert :ok = Session.stop(session)
    end
  end

  defp safe_stop(session) do
    Session.stop(session)
  catch
    _, _ -> :ok
  end
end
