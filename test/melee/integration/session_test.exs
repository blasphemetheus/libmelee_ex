defmodule Melee.Integration.SessionTest do
  use ExUnit.Case

  @moduledoc """
  End-to-end check of `Melee.Session` against a real Dolphin: one call
  launches the emulator, connects the console and opens the controller
  fifo, and `step/2` yields live frames.

  Excluded by default; it launches Dolphin itself:

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_session
  """

  alias Melee.{Controller, GameState, Session}

  @moduletag :dolphin
  @moduletag :dolphin_session
  @moduletag timeout: 300_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_session_it")

  # Guard against a vacuous pass with WALL CLOCK, not step counts:
  # polling coalesces console steps, so 300 "steps" can be a fraction of
  # a second of emulation. Booting Dolphin and reaching a frame-producing
  # scene cannot happen in under a second.
  @min_run_ms 1_000

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

  test "starts a whole session and steps live frames", ctx do
    if ctx[:skip] do
      IO.puts("SKIPPED: #{ctx.skip}")
    else
      started_at = System.monotonic_time(:millisecond)

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_601,
          headless: true,
          gfx_backend: "Null",
          blocking_input: false,
          ports: [1],
          console: [polling_mode: true, polling_timeout: 100, reconnect: [attempts: 3]]
        )

      on_exit(fn -> Session.stop(session) end)

      controller = Session.controller(session, 1)
      assert is_pid(controller)
      assert %Melee.Dolphin{} = Session.dolphin(session)

      # Drive until frames flow (menus tick too), giving the boot a
      # generous budget.
      frames = collect_frames(session, controller, 400, [])

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms >= @min_run_ms, "suspiciously fast: #{elapsed_ms}ms"
      assert frames != [], "no frames in #{elapsed_ms}ms"

      numbers = Enum.map(frames, & &1.frame)
      assert numbers == Enum.sort(numbers)

      assert :ok = Session.stop(session)
      refute Process.alive?(session)
    end
  end

  defp collect_frames(_session, _controller, 0, acc), do: Enum.reverse(acc)

  defp collect_frames(session, controller, budget, acc) do
    Controller.release_all(controller)

    case Session.step(session, 30_000) do
      {:ok, %GameState{} = gs} -> collect_frames(session, controller, budget - 1, [gs | acc])
      nil -> collect_frames(session, controller, budget - 1, acc)
      {:error, :enet_disconnected} -> Enum.reverse(acc)
    end
  end
end
