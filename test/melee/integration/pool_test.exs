defmodule Melee.Integration.PoolTest do
  use ExUnit.Case

  @moduledoc """
  The fleet, live: `Melee.SessionPool` runs three headless Dolphins at
  once, and each one is driven to a running match CONCURRENTLY through
  `Melee.Match.play/2`. Distinct emulator pids, distinct spectator
  ports, three simultaneous games — the eval-farm shape actually
  exercised, not just unit-tested.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_pool
  """

  alias Melee.{GameState, Match, Session, SessionPool}

  @moduletag :dolphin
  @moduletag :dolphin_pool
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_pool_it")
  @count 3

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

  test "#{@count} concurrent sessions each reach a running match", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"
      started = System.monotonic_time(:millisecond)

      {:ok, pool} =
        SessionPool.start_link(
          count: @count,
          base_port: 51_580,
          session: [
            path: ctx.path,
            iso_path: ctx.iso,
            home: @home,
            headless: not windowed?,
            gfx_backend: if(windowed?, do: "OGL", else: "Null"),
            blocking_input: true,
            ports: [1, 2],
            console: [polling_mode: true, polling_timeout: 100]
          ]
        )

      on_exit(fn -> safe_stop(pool) end)

      sessions = SessionPool.sessions(pool)
      assert length(sessions) == @count

      # Distinct emulators on distinct spectator ports.
      dolphins = for {_i, s} <- sessions, do: Session.dolphin(s)
      os_pids = Enum.map(dolphins, & &1.os_pid)
      slippi_ports = Enum.map(dolphins, & &1.slippi_port)
      assert length(Enum.uniq(os_pids)) == @count
      assert length(Enum.uniq(slippi_ports)) == @count

      # Drive all three to in-game at the same time.
      results =
        sessions
        |> Enum.map(fn {i, session} ->
          Task.async(fn ->
            {i,
             Match.play(session,
               p1: [character: :fox],
               p2: [character: :falco],
               stage: :final_destination
             )}
          end)
        end)
        |> Task.await_many(120_000)

      for {i, result} <- results do
        assert {:ok, gamestate} = result
        assert GameState.in_game?(gamestate), "session #{i} never reached a match"
      end

      elapsed = System.monotonic_time(:millisecond) - started
      IO.puts("\n[dolphin] pool: #{@count} concurrent matches in #{elapsed}ms")
    end
  end

  defp safe_stop(pool) do
    GenServer.stop(pool)
  catch
    _, _ -> :ok
  end
end
