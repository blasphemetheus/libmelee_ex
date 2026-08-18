defmodule Melee.Transport.Direct do
  @moduledoc """
  The Slippi **direct channel**: a unix domain socket carrying raw event
  payloads, instead of ENet + JSON + base64 over UDP.

  Requires a Dolphin build with the direct-channel patch (the
  `spectator-flush-on-frame` branch of blasphemetheus/slippi-Ishiiruka)
  and `SlippiDirectChannelPath` set in `Dolphin.ini` — which
  `Melee.Dolphin.launch(direct_channel: true)` does, placing the socket
  at `<home>/Slippi/direct.sock`. Dolphin sends each payload from the
  GAME thread as `<u32 big-endian length><payload>`, which maps
  exactly onto `:gen_tcp`'s `packet: 4` framing.

  Implements the `Melee.Transport` message contract so
  `Melee.Console` can use it like any transport — but the payloads are
  RAW Slippi events, not Slippstream JSON, so the console must run
  with `protocol: :raw` (Melee.Session wires both together via its
  `direct_channel: true` option).

  `connect/4` ignores host/port; the socket path comes from
  `opts[:path]`. `send/4` is a no-op: the direct channel has no
  handshake and (so far) carries nothing client-to-Dolphin.
  """

  @behaviour Melee.Transport

  use GenServer

  @impl Melee.Transport
  def connect(_host, _port, owner, opts) do
    path = Keyword.fetch!(opts, :path)

    # Connect in the CALLER so a socket that isn't there yet (Dolphin
    # still booting) comes back as a plain {:error, :enoent} the
    # caller's retry loop can absorb — a linked GenServer dying in
    # init would take the console down with it instead. The socket is
    # then handed to the transport process before going active.
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: 4]) do
      {:ok, socket} ->
        {:ok, pid} = GenServer.start_link(__MODULE__, {socket, owner})
        :ok = :gen_tcp.controlling_process(socket, pid)
        GenServer.cast(pid, :activate)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Melee.Transport
  def send(_conn, _channel, _data, :reliable), do: :ok

  @impl Melee.Transport
  def disconnect(conn) do
    GenServer.stop(conn, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def init({socket, owner}) do
    {:ok, %{socket: socket, owner: owner}}
  end

  @impl GenServer
  def handle_cast(:activate, state) do
    # packet: 4 matches the channel's u32 big-endian length framing;
    # each message arrives whole.
    :ok = :inet.setopts(state.socket, active: true)
    Kernel.send(state.owner, {:enet_connected, self()})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    Kernel.send(state.owner, {:enet_packet, self(), 0, data})
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Kernel.send(state.owner, {:enet_disconnected, self(), :closed})
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Kernel.send(state.owner, {:enet_disconnected, self(), reason})
    {:stop, :normal, state}
  end
end
