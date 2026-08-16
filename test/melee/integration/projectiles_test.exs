defmodule Melee.Integration.ProjectilesTest do
  use ExUnit.Case

  @moduledoc """
  The projectile decoder, live-asserted for the first time: Fox fires
  his blaster and the lasers must show up in `gamestate.projectiles`
  with the right type and sane physics. (The peppi differential does
  not compare projectiles, so nothing else vouches for this decode
  path against a real game.)

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_projectiles
  """

  alias Melee.{Controller, Enums, GameState, Match, Session}

  @moduletag :dolphin
  @moduletag :dolphin_projectiles
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_projectiles_it")
  @fox_laser Enums.ProjectileType.to_id(:fox_laser)

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

  test "Fox's lasers appear in gamestate.projectiles", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_588,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          blocking_input: true,
          ports: [1, 2],
          console: [polling_mode: true, polling_timeout: 100]
        )

      on_exit(fn -> safe_stop(session) end)

      {:ok, _first} =
        Match.play(session,
          p1: [character: :fox],
          p2: [character: :falco],
          stage: :final_destination
        )

      controller = Session.controller(session, 1)

      # Ride out the entry animation, then mash B: standing neutral-B is
      # the blaster. Collect every projectile seen over ~300 frames.
      lasers =
        Enum.reduce(1..390, [], fn i, acc ->
          if i > 90 do
            # Pulse B so each shot is a fresh edge.
            if rem(i, 6) in [0, 1],
              do: Controller.press_button(controller, :b),
              else: Controller.release_button(controller, :b)
          else
            Controller.release_all(controller)
          end

          case Session.step(session) do
            {:ok, gamestate} -> gamestate.projectiles ++ acc
            nil -> acc
            {:error, _} -> acc
          end
        end)

      assert lasers != [], "no projectiles observed while mashing the blaster"

      types = lasers |> Enum.map(& &1.type) |> Enum.uniq()
      assert @fox_laser in types, "expected fox_laser (#{@fox_laser}) in #{inspect(types)}"

      # Sane physics: lasers exist on the stage, moving horizontally.
      fox_lasers = Enum.filter(lasers, &(&1.type == @fox_laser))

      for laser <- Enum.take(fox_lasers, 20) do
        assert abs(laser.position.x) < 260
        assert abs(laser.position.y) < 200
      end

      assert Enum.any?(fox_lasers, &(abs(&1.speed.x) > 0.5)),
             "every laser had ~zero x speed — speed decode suspect"

      IO.puts("\n[dolphin] projectiles: #{length(fox_lasers)} fox-laser rows observed")

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
