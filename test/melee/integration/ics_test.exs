defmodule Melee.Integration.IcsTest do
  use ExUnit.Case

  @moduledoc """
  Ice Climbers, live: the one character that puts TWO bodies on one
  port. Nana's follower frames (`is_follower` byte set) must decode
  into `player.nana` with her own live physics — the follower path is
  exercised by the replay tests, but had never been asserted against a
  real game.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_ics
  """

  alias Melee.{Controller, Enums, Match, Session}

  @moduletag :dolphin
  @moduletag :dolphin_ics
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_ics_it")

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

  test "Nana arrives as player.nana with her own live physics", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_587,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          blocking_input: true,
          ports: [1, 2],
          console: [polling_mode: true, polling_timeout: 100]
        )

      on_exit(fn -> safe_stop(session) end)

      {:ok, _first} =
        Match.play(session,
          p1: [character: :popo],
          p2: [character: :falco],
          stage: :final_destination
        )

      controller = Session.controller(session, 1)

      # Walk right for a while, sampling Popo and Nana.
      samples =
        Enum.reduce(1..300, [], fn i, acc ->
          if i > 90,
            do: Controller.tilt_analog(controller, :main, 1.0, 0.5),
            else: Controller.release_all(controller)

          case Session.step(session) do
            {:ok, gamestate} ->
              case gamestate.players[1] do
                nil -> acc
                popo -> [{popo, popo.nana} | acc]
              end

            _ ->
              acc
          end
        end)

      with_nana = for {_popo, nana} when nana != nil <- samples, do: nana

      assert with_nana != [], "Nana never appeared on port 1"

      assert length(with_nana) > 200,
             "Nana present on only #{length(with_nana)}/#{length(samples)} frames"

      # Nana is her own body: IC character, her own positions, moving.
      assert Enum.all?(with_nana, &(&1.character == Enums.Character.to_id(:nana)))

      xs = with_nana |> Enum.map(& &1.position.x) |> Enum.uniq()
      assert length(xs) > 20, "Nana's x never moved — stale follower decode?"

      # And she is genuinely a separate body from Popo, not a copy.
      apart? =
        Enum.any?(samples, fn
          {popo, %{} = nana} -> abs(popo.position.x - nana.position.x) > 0.5
          _ -> false
        end)

      assert apart?, "Nana's position always identical to Popo's"

      IO.puts("\n[dolphin] ics: Nana live on #{length(with_nana)}/#{length(samples)} frames")

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
