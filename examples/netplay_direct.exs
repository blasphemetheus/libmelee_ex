# Netplay Direct live test: bot-vs-bot through real Slippi matchmaking,
# both sides on the NATIVE bridge. Side A plays as the bot account
# (EXPH#288) connecting to DBTD#411; side B plays as the main account
# connecting to EXPH#288.
#
# Verifies: Direct menu flow (connect-code entry), user_home copying,
# in-game frames over netplay, own_port detection via connect codes.
#
# Run from exphil: devenv shell -- mix run <this file>

alias ExPhil.Bridge.MeleePort

defmodule DirectTest do
  # Direct requires the netplay-stable build (the ExiAI build's online menu
  # is inert — confirmed via Python oracle). Null gfx: window opens, renders
  # nothing.
  @dolphin Path.expand("~/.local/share/slippi/netplay/Slippi_Online-x86_64.AppImage")
  @iso "/home/blewf/isos/melee.iso"
  @in_game_target 600

  def side(name, user_home, opponent_code, slippi_port) do
    {:ok, bridge} = MeleePort.start_link([])

    config = %{
      dolphin_path: @dolphin,
      iso_path: @iso,
      headless: false,
      gfx_backend: "Null",
      character: :fox,
      stage: :battlefield,
      connect_code: opponent_code,
      user_home: user_home,
      slippi_port: slippi_port,
      console_timeout: 0.1,
      online_delay: 0
    }

    IO.puts("[#{name}] init (as #{Path.basename(user_home)} -> #{opponent_code})")

    case MeleePort.init_console(bridge, config, 120_000) do
      {:ok, _} ->
        IO.puts("[#{name}] initialized; entering Direct flow")
        loop(bridge, name, %{in_game: 0, last_menu: nil, own_port: nil, started: now()})

      {:error, reason} ->
        IO.puts("[#{name}] init FAILED: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp loop(bridge, name, acc) do
    cond do
      acc.in_game >= @in_game_target ->
        IO.puts("[#{name}] SUCCESS: #{acc.in_game} netplay frames, own_port=#{inspect(acc.own_port)}")
        MeleePort.stop(bridge)
        {:ok, acc.own_port}

      now() - acc.started > 240_000 ->
        IO.puts("[#{name}] TIMEOUT at in_game=#{acc.in_game} last_menu=#{inspect(acc.last_menu)}")
        MeleePort.stop(bridge)
        {:error, :timeout}

      true ->
        case MeleePort.step(bridge, [], 90_000) do
          {:ok, gs} ->
            own = gs.own_port || acc.own_port

            if acc.in_game == 0 do
              codes = for {port, p} <- gs.players, do: {port, p && p.connect_code}
              IO.puts("[#{name}] IN GAME frame=#{gs.frame} own_port=#{inspect(gs.own_port)} codes=#{inspect(codes)}")
            end

            if rem(acc.in_game, 300) == 0 and acc.in_game > 0 do
              IO.puts("[#{name}] frame #{gs.frame} (#{acc.in_game} in-game frames)")
            end

            :ok = MeleePort.send_controller(bridge, %{main_stick: %{x: 0.5, y: 0.5}, buttons: %{}})
            loop(bridge, name, %{acc | in_game: acc.in_game + 1, own_port: own})

          {:menu, gs} ->
            if gs.menu_state != acc.last_menu do
              IO.puts("[#{name}] menu_state -> #{gs.menu_state}")
            end

            loop(bridge, name, %{acc | last_menu: gs.menu_state})

          :no_frame ->
            loop(bridge, name, acc)

          other ->
            IO.puts("[#{name}] ended: #{inspect(other)}")
            MeleePort.stop(bridge)
            {:error, other}
        end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end

bot_home = Path.expand("~/.config/SlippiOnline-bot")
main_home = Path.expand("~/.config/SlippiOnline")

task_a = Task.async(fn -> DirectTest.side("A/EXPH", bot_home, "DBTD#411", 51_500) end)
# Stagger slightly so both aren't hammering matchmaking at the same instant.
Process.sleep(5_000)
task_b = Task.async(fn -> DirectTest.side("B/DBTD", main_home, "EXPH#288", 51_501) end)

result_a = Task.await(task_a, 300_000)
result_b = Task.await(task_b, 300_000)

IO.puts("[direct] A=#{inspect(result_a)} B=#{inspect(result_b)}")

case {result_a, result_b} do
  {{:ok, port_a}, {:ok, port_b}} ->
    IO.puts("[direct] NETPLAY DIRECT OK — own_ports #{inspect(port_a)}/#{inspect(port_b)}")

  _ ->
    IO.puts("[direct] FAILED")
    System.halt(1)
end
