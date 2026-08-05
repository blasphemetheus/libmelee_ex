defmodule Melee.Transport.EnetBeamTest do
  use ExUnit.Case, async: false

  @moduletag :enet_beam

  alias Melee.Transport.EnetBeam
  alias Melee.Transport.EnetNif.Native

  doctest Melee.Transport.EnetBeam.Protocol
  doctest Melee.Transport.EnetBeam.Channel

  # Wire-compatibility harness: the Rustler NIF (rusty_enet, stock ENet
  # 1.3.18 semantics) acts as the server; EnetBeam must interoperate with
  # it. The pump forwards server events as {:server_event, event}.
  setup do
    {:ok, server} = Native.host_listen(0)
    {:ok, port} = Native.host_port(server)

    test_pid = self()
    spawn_link(fn -> pump_loop(server, test_pid) end)

    on_exit(fn -> Native.host_destroy(server) end)

    %{server: server, port: port}
  end

  defp pump_loop(server, test_pid) do
    case Native.host_service(server, 50) do
      {:ok, events} ->
        Enum.each(events, &Kernel.send(test_pid, {:server_event, &1}))
        pump_loop(server, test_pid)

      {:error, _reason} ->
        :ok
    end
  end

  defp connect!(port) do
    {:ok, conn} = EnetBeam.connect("127.0.0.1", port, self())
    assert_receive {:enet_connected, ^conn}, 5_000
    assert_receive {:server_event, :connected}, 5_000
    conn
  end

  describe "connect handshake" do
    test "completes against the NIF server within 5s", %{port: port} do
      conn = connect!(port)
      :ok = EnetBeam.disconnect(conn)
    end
  end

  describe "reliable send" do
    test "the JSON handshake reaches the NIF server", %{port: port} do
      conn = connect!(port)

      handshake = Jason.encode!(%{type: "connect_request", cursor: 0})
      assert :ok = EnetBeam.send(conn, 0, handshake, :reliable)
      assert_receive {:server_event, {:packet, 0, ^handshake}}, 5_000

      :ok = EnetBeam.disconnect(conn)
    end
  end

  describe "reliable receive" do
    test "small server packets arrive intact", %{server: server, port: port} do
      conn = connect!(port)

      payload = Jason.encode!(%{type: "game_event", payload: "AAAA"})
      assert :ok = Native.server_send(server, 0, payload)
      assert_receive {:enet_packet, ^conn, 0, ^payload}, 5_000

      :ok = EnetBeam.disconnect(conn)
    end

    test "a 64 KiB packet is reassembled from fragments intact", %{server: server, port: port} do
      conn = connect!(port)

      big = :crypto.strong_rand_bytes(64 * 1024)
      sent_hash = :crypto.hash(:sha256, big)

      assert :ok = Native.server_send(server, 0, big)

      assert_receive {:enet_packet, ^conn, 0, received}, 10_000
      assert byte_size(received) == 64 * 1024
      assert :crypto.hash(:sha256, received) == sent_hash

      :ok = EnetBeam.disconnect(conn)
    end

    test "50 rapid packets are delivered in order", %{server: server, port: port} do
      conn = connect!(port)

      for i <- 1..50 do
        assert :ok = Native.server_send(server, 0, <<i::32>>)
      end

      received =
        for _ <- 1..50 do
          assert_receive {:enet_packet, ^conn, 0, <<i::32>>}, 5_000
          i
        end

      assert received == Enum.to_list(1..50)

      :ok = EnetBeam.disconnect(conn)
    end
  end

  describe "disconnect and keepalive" do
    test "destroying the server host notifies the owner", %{server: server, port: port} do
      conn = connect!(port)

      ref = Process.monitor(conn)
      :ok = Native.host_destroy(server)

      assert_receive {:enet_disconnected, ^conn, _reason}, 8_000
      assert_receive {:DOWN, ^ref, :process, ^conn, :normal}, 1_000
    end

    test "connection survives 6+ seconds of idle, then still delivers", %{
      server: server,
      port: port
    } do
      conn = connect!(port)

      refute_receive {:enet_disconnected, ^conn, _reason}, 6_500

      payload = "still alive"
      assert :ok = Native.server_send(server, 0, payload)
      assert_receive {:enet_packet, ^conn, 0, ^payload}, 5_000

      :ok = EnetBeam.disconnect(conn)
    end

    test "disconnect/1 is idempotent and safe on a dead conn", %{port: port} do
      conn = connect!(port)

      assert :ok = EnetBeam.disconnect(conn)
      assert :ok = EnetBeam.disconnect(conn)
      assert {:error, :closed} = EnetBeam.send(conn, 0, "late", :reliable)
    end
  end
end
