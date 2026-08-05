defmodule Melee.ConsoleTest do
  use ExUnit.Case, async: true

  alias Melee.{Console, Slippstream}

  # A Melee.Transport that hands control to the test process: connect and
  # send are relayed back to the test, and the test injects inbound events
  # by sending the console the behaviour's messages directly.
  defmodule RelayTransport do
    @behaviour Melee.Transport

    @impl true
    def connect(_host, _port, owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:transport_connect, owner})
      {:ok, {:relay, test_pid}}
    end

    @impl true
    def send({:relay, test_pid}, channel, data, :reliable) do
      send(test_pid, {:transport_send, channel, data})
      :ok
    end

    @impl true
    def disconnect({:relay, test_pid}) do
      send(test_pid, :transport_disconnect)
      :ok
    end
  end

  # --- Slippi event stream builders (same wire format as events_test) ------

  defp u8(v), do: <<v>>
  defp u16(v), do: <<v::big-unsigned-16>>
  defp i32(v), do: <<v::big-signed-32>>
  defp f32(v), do: <<v::big-float-32>>

  defp event(command, size, fields) do
    base = <<command>> <> :binary.copy(<<0>>, size - 1)

    Enum.reduce(Map.merge(%{}, Map.new(fields)), base, fn {off, value}, acc ->
      before_part = binary_part(acc, 0, off)
      after_start = off + byte_size(value)
      after_part = binary_part(acc, after_start, byte_size(acc) - after_start)
      before_part <> value <> after_part
    end)
  end

  @sizes %{0x36 => 0x2ED, 0x37 => 0x41, 0x38 => 0x85, 0x39 => 0x2, 0x3B => 0x2C, 0x3C => 0x9}

  defp payloads do
    table = for {cmd, size} <- @sizes, into: <<>>, do: <<cmd, size - 1::big-unsigned-16>>
    <<0x35, byte_size(table) + 1>> <> table
  end

  defp game_start do
    event(0x36, @sizes[0x36], [
      {0x1, u8(3)},
      {0x2, u8(16)},
      {0x13, u16(0x20)},
      {0x66, u8(0)},
      {0x66 + 0x24, u8(0)}
    ])
  end

  defp frame(n) do
    event(0x37, @sizes[0x37], [{0x1, i32(n)}, {0x5, u8(0)}]) <>
      event(0x38, @sizes[0x38], [
        {0x1, i32(n)},
        {0x5, u8(0)},
        {0x7, u8(0x1)},
        {0x8, u16(14)},
        {0xA, f32(1.0 * n)}
      ]) <>
      event(0x3C, @sizes[0x3C], [{0x1, i32(n)}])
  end

  defp game_event_packet(bin) do
    Jason.encode!(%{"type" => "game_event", "payload" => Base.encode64(bin)})
  end

  # --- test harness ---------------------------------------------------------

  defp connected_console(_ctx, opts \\ []) do
    {:ok, console} =
      Console.start_link(
        Keyword.merge(
          [transport: RelayTransport, transport_opts: [test_pid: self()]],
          opts
        )
      )

    task = Task.async(fn -> Console.connect(console, 5_000) end)

    assert_receive {:transport_connect, owner}
    send(owner, {:enet_connected, {:relay, self()}})

    assert :ok = Task.await(task, 5_000)

    # ENet connect complete → the JSON handshake goes out reliably on ch 0.
    assert_receive {:transport_send, 0, handshake}
    assert handshake == Slippstream.connect_request()

    {console, owner}
  end

  defp inject(owner, packet), do: send(owner, {:enet_packet, {:relay, self()}, 0, packet})

  describe "connect/2" do
    test "completes the enet + slippstream handshake", ctx do
      {console, _owner} = connected_console(ctx)
      # connect_reply hasn't arrived yet.
      refute Console.connected?(console)
    end

    test "records peer info from connect_reply", ctx do
      {console, owner} = connected_console(ctx)

      inject(
        owner,
        Jason.encode!(%{
          "type" => "connect_reply",
          "nick" => "Slippi Console",
          "version" => "3.4.0",
          "cursor" => 7
        })
      )

      # step processes buffered messages; give it a frame to return.
      inject(owner, game_event_packet(payloads() <> game_start() <> frame(1)))
      assert {:ok, _gs} = Console.step(console, 5_000)

      assert Console.connected?(console)
      info = Console.info(console)
      assert info.nick == "Slippi Console"
      assert info.version == "3.4.0"
      assert info.cursor == 7
    end
  end

  describe "step/2" do
    test "returns completed frames in order", ctx do
      {console, owner} = connected_console(ctx)

      inject(owner, game_event_packet(payloads() <> game_start() <> frame(1)))
      inject(owner, game_event_packet(frame(2)))

      assert {:ok, gs1} = Console.step(console, 5_000)
      assert gs1.frame == 1
      assert gs1.players[1].position.x == 1.0

      assert {:ok, gs2} = Console.step(console, 5_000)
      assert gs2.frame == 2
    end

    test "blocks until a frame arrives", ctx do
      {console, owner} = connected_console(ctx)
      inject(owner, game_event_packet(payloads() <> game_start()))

      task = Task.async(fn -> Console.step(console, 5_000) end)
      refute_receive _, 100

      inject(owner, game_event_packet(frame(1)))
      assert {:ok, gs} = Task.await(task, 5_000)
      assert gs.frame == 1
    end

    test "menu events complete frames too", ctx do
      {console, owner} = connected_console(ctx)
      inject(owner, game_event_packet(payloads()))

      # scene 0x0008 = Slippi Online CSS; frame counter at 0x39
      menu = event(0x3E, 0x45, [{0x1, u16(0x0008)}, {0x39, i32(42)}])
      inject(owner, Jason.encode!(%{"type" => "menu_event", "payload" => Base.encode64(menu)}))

      assert {:ok, gs} = Console.step(console, 5_000)
      # SLIPPI_ONLINE_CSS
      assert gs.menu_state == 6
      assert gs.frame == 42
    end

    test "polling mode returns nil when no frame is available", ctx do
      {console, _owner} = connected_console(ctx, polling_mode: true, polling_timeout: 50)
      assert Console.step(console, 5_000) == nil
    end

    test "enet disconnect surfaces as an error", ctx do
      {console, owner} = connected_console(ctx)
      send(owner, {:enet_disconnected, {:relay, self()}, :peer_disconnected})

      assert {:error, :enet_disconnected} = Console.step(console, 5_000)
      # And stays that way.
      assert {:error, :enet_disconnected} = Console.step(console, 5_000)
    end

    test "game end is not terminal: menu events still step afterwards", ctx do
      {console, owner} = connected_console(ctx)

      game_end = event(0x39, @sizes[0x39], [])
      inject(owner, game_event_packet(payloads() <> game_start() <> frame(1) <> game_end))

      assert {:ok, %{frame: 1}} = Console.step(console, 5_000)

      menu = event(0x3E, 0x45, [{0x1, u16(0x0001)}, {0x39, i32(9)}])
      inject(owner, Jason.encode!(%{"type" => "menu_event", "payload" => Base.encode64(menu)}))

      assert {:ok, gs} = Console.step(console, 5_000)
      # MAIN_MENU
      assert gs.menu_state == 5
    end
  end

  describe "controllers" do
    defp file_controller(ctx) do
      path = Path.join(System.tmp_dir!(), "melee_console_ctl_#{:erlang.phash2(ctx.test)}")
      File.rm(path)
      {:ok, pid} = Melee.Controller.start_link(pipe_path: path)
      :ok = Melee.Controller.connect(pid)
      {pid, path}
    end

    test "step flushes registered controllers first", ctx do
      {console, owner} = connected_console(ctx)
      {controller, path} = file_controller(ctx)
      :ok = Console.register_controller(console, controller)

      inject(owner, game_event_packet(payloads() <> game_start() <> frame(1)))
      assert {:ok, _} = Console.step(console, 5_000)

      content = File.read!(path)
      assert content =~ "FLUSH\n"
      # game_start also releases all inputs so frame one has neutral input.
      assert content =~ "RELEASE A\n"
      assert content =~ "SET MAIN .5 .5\n"
    end
  end
end
