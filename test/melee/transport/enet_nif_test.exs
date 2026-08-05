defmodule Melee.Transport.EnetNifTest do
  use ExUnit.Case, async: false

  @moduletag :enet_nif

  alias Melee.Transport.EnetNif
  alias Melee.Transport.EnetNif.Native

  # Loopback harness: a NIF server host on an ephemeral 127.0.0.1 port,
  # pumped by a spawned process that forwards its events to the test pid
  # as {:server_event, event} messages.
  setup do
    {:ok, server} = Native.host_listen(0)
    {:ok, port} = Native.host_port(server)

    test_pid = self()
    pump = spawn_link(fn -> pump_loop(server, test_pid) end)

    on_exit(fn -> Native.host_destroy(server) end)

    %{server: server, port: port, pump: pump}
  end

  defp pump_loop(server, test_pid) do
    case Native.host_service(server, 50) do
      {:ok, events} ->
        Enum.each(events, &Kernel.send(test_pid, {:server_event, &1}))
        pump_loop(server, test_pid)

      {:error, _reason} ->
        # Host destroyed — stop pumping.
        :ok
    end
  end

  describe "loopback connect and packet exchange" do
    test "connects and both sides observe the handshake", %{port: port} do
      {:ok, conn} = EnetNif.connect("127.0.0.1", port, self())

      assert_receive {:enet_connected, ^conn}, 5_000
      assert_receive {:server_event, :connected}, 5_000

      :ok = EnetNif.disconnect(conn)
    end

    test "reliable packets flow in both directions", %{server: server, port: port} do
      {:ok, conn} = EnetNif.connect("127.0.0.1", port, self())
      assert_receive {:enet_connected, ^conn}, 5_000
      assert_receive {:server_event, :connected}, 5_000

      # Client -> server (the handshake direction Dolphin expects).
      handshake = Jason.encode!(%{type: "connect_request", cursor: 0})
      assert :ok = EnetNif.send(conn, 0, handshake, :reliable)
      assert_receive {:server_event, {:packet, 0, ^handshake}}, 5_000

      # Server -> client (the event-stream direction).
      payload = Jason.encode!(%{type: "game_event", payload: "AAAA"})
      assert :ok = Native.server_send(server, 0, payload)
      assert_receive {:enet_packet, ^conn, 0, ^payload}, 5_000

      :ok = EnetNif.disconnect(conn)
    end

    test "a 64 KiB packet is fragmented and reassembled intact", %{server: server, port: port} do
      {:ok, conn} = EnetNif.connect("127.0.0.1", port, self())
      assert_receive {:enet_connected, ^conn}, 5_000
      assert_receive {:server_event, :connected}, 5_000

      big = :crypto.strong_rand_bytes(64 * 1024)
      sent_hash = :crypto.hash(:sha256, big)

      assert :ok = Native.server_send(server, 0, big)

      assert_receive {:enet_packet, ^conn, 0, received}, 10_000
      assert byte_size(received) == 64 * 1024
      assert :crypto.hash(:sha256, received) == sent_hash

      :ok = EnetNif.disconnect(conn)
    end
  end

  describe "disconnect propagation" do
    test "destroying the server host notifies the owner", %{server: server, port: port} do
      {:ok, conn} = EnetNif.connect("127.0.0.1", port, self())
      assert_receive {:enet_connected, ^conn}, 5_000
      assert_receive {:server_event, :connected}, 5_000

      ref = Process.monitor(conn)
      :ok = Native.host_destroy(server)

      assert_receive {:enet_disconnected, ^conn, _reason}, 5_000
      # The conn GenServer terminates after forwarding the disconnect.
      assert_receive {:DOWN, ^ref, :process, ^conn, :normal}, 1_000
    end

    test "disconnect/1 is idempotent and safe on a dead conn", %{port: port} do
      {:ok, conn} = EnetNif.connect("127.0.0.1", port, self())
      assert_receive {:enet_connected, ^conn}, 5_000

      assert :ok = EnetNif.disconnect(conn)
      assert :ok = EnetNif.disconnect(conn)
      assert {:error, :closed} = EnetNif.send(conn, 0, "late", :reliable)
    end
  end
end
