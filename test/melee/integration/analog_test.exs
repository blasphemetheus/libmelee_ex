defmodule Melee.Integration.AnalogTest do
  use ExUnit.Case

  @moduledoc """
  The analog input loop, verified numerically against the live game —
  and the contract it found: **what you send is what you read back**.

  `Melee.Controller.fix_analog_stick/1` compresses `0..1` onto the wire
  range (`~0.185..0.815`), and Melee's own calibration exactly inverts
  that back to full deflection — which is precisely WHY libmelee
  quantizes this way. So for every value outside the deadzone,
  `gamestate.players[p].controller_state.main_stick` reports the
  ORIGINAL sent value (as an f32); sent values in `[0.4, 0.6]` sit
  inside Melee's deadzone and read back as exact neutral. Measured with
  a 21-point sweep; the boundary points 0.35 and 0.65 pass through
  untouched.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_analog
  """

  alias Melee.{Controller, Match, Session}

  @moduletag :dolphin
  @moduletag :dolphin_analog
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_analog_it")

  # f32 round-trip slop only; the mapping itself is exact.
  @eps 1.0e-6

  @identity [0.0, 0.05, 0.1, 0.2, 0.3, 0.35, 0.65, 0.7, 0.8, 0.9, 0.95, 1.0]
  @deadzone [0.4, 0.45, 0.5, 0.55, 0.6]

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

  test "stick values round-trip as the identity, deadzone [0.4, 0.6] as neutral", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_586,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          blocking_input: true,
          ports: [1, 2],
          console: [polling_mode: true, polling_timeout: 100]
        )

      on_exit(fn -> safe_stop(session) end)

      {:ok, _} =
        Match.play(session,
          p1: [character: :fox],
          p2: [character: :falco],
          stage: :final_destination
        )

      controller = Session.controller(session, 1)

      # Ride out the entry animation.
      Enum.each(1..90, fn _ ->
        Controller.release_all(controller)
        Session.step(session)
      end)

      readback = fn x ->
        Controller.tilt_analog(controller, :main, x, 0.5)

        # Hold for a few frames; take the last reading.
        Enum.reduce(1..6, nil, fn _i, acc ->
          case Session.step(session) do
            {:ok, gs} -> (gs.players[1] && gs.players[1].controller_state.main_stick) || acc
            _ -> acc
          end
        end)
      end

      for x <- @identity do
        {got_x, got_y} = readback.(x)
        assert_in_delta got_x, x, @eps, "sent #{x}, game reported #{got_x}"
        assert_in_delta got_y, 0.5, @eps
      end

      for x <- @deadzone do
        {got_x, _} = readback.(x)
        assert_in_delta got_x, 0.5, @eps, "sent #{x} (deadzone), game reported #{got_x}"
      end

      IO.puts(
        "\n[dolphin] analog: #{length(@identity)} identity round-trips, " <>
          "#{length(@deadzone)} deadzone collapses — all exact"
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
