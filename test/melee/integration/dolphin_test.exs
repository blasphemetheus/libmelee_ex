defmodule Melee.Integration.DolphinTest do
  use ExUnit.Case

  @moduledoc """
  Integration tests against a real, running Slippi Dolphin.

  Excluded by default. Start Dolphin (with the Melee ISO booted or in
  menus) per exphil's docs/guides/DOLPHIN.md, then:

      mix test --only dolphin

  Set `MELEE_DOLPHIN_HOME` to also exercise the controller fifo path
  (requires the pad config from `Melee.DolphinConfig.setup_controller/3`
  and a Dolphin restart after first setup).
  """

  alias Melee.{Console, Controller, DolphinConfig, GameState}

  @moduletag :dolphin
  @moduletag timeout: 120_000

  # MELEE_SPECTATOR_PORT overrides the default 51441; MELEE_TRANSPORT=beam
  # exercises the pure-Elixir ENet client instead of the Rust NIF.
  defp console_opts do
    port = String.to_integer(System.get_env("MELEE_SPECTATOR_PORT", "51441"))

    transport =
      case System.get_env("MELEE_TRANSPORT", "nif") do
        "beam" -> Melee.Transport.EnetBeam
        _ -> Melee.Transport.EnetNif
      end

    [port: port, transport: transport]
  end

  test "connects, receives connect_reply, and steps live frames at ~60Hz" do
    {:ok, console} = Console.start_link(console_opts())
    assert :ok = Console.connect(console, 10_000)

    # First step also processes the connect_reply.
    assert {:ok, %GameState{} = first} = Console.step(console, 30_000)
    assert Console.connected?(console)

    info = Console.info(console)
    assert info.nick != "" or info.version != ""

    {elapsed_us, frames} =
      :timer.tc(fn ->
        for _ <- 1..120, do: Console.step(console, 5_000)
      end)

    gamestates = for {:ok, gs} <- frames, do: gs

    assert length(gamestates) == 120

    # In-game: frames advance monotonically. In menus: menu frames tick too.
    numbers = Enum.map(gamestates, & &1.frame)
    assert numbers == Enum.sort(numbers)

    # 120 frames should take about 2 seconds of wall clock (60 fps),
    # generously bounded for slow starts.
    assert elapsed_us < 10_000_000

    IO.puts(
      "\n[dolphin] first frame #{first.frame}, menu_state #{first.menu_state}, " <>
        "120 frames in #{div(elapsed_us, 1000)}ms (#{info.nick} #{info.version})"
    )

    Console.stop(console)
  end

  @tag :dolphin_controller
  test "drives controller input in the character select screen" do
    dolphin_home = System.get_env("MELEE_DOLPHIN_HOME")

    if dolphin_home == nil do
      IO.puts("\n[dolphin] MELEE_DOLPHIN_HOME not set; skipping controller test")
    else
      {:ok, pipe} = DolphinConfig.setup_controller(dolphin_home, 1)

      {:ok, console} = Console.start_link(console_opts())
      {:ok, controller} = Controller.start_link(pipe_path: pipe)

      assert :ok = Console.connect(console, 10_000)
      :ok = Console.register_controller(console, controller)
      assert :ok = Controller.connect(controller, 30_000)

      # Wiggle the cursor and press A; a human watching CSS sees movement.
      for i <- 1..180 do
        x = 0.5 + 0.4 * :math.sin(i / 20)
        Controller.tilt_analog(controller, :main, x, 0.5)
        if rem(i, 60) == 0, do: Controller.press_button(controller, :a)
        if rem(i, 60) == 30, do: Controller.release_button(controller, :a)
        assert {:ok, _gs} = Console.step(console, 5_000)
      end

      Controller.release_all(controller)
      Controller.disconnect(controller)
      Console.stop(console)
    end
  end
end
