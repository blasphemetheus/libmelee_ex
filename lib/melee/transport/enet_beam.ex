defmodule Melee.Transport.EnetBeam do
  @moduledoc """
  BEAM-native `Melee.Transport`: a minimal pure-Elixir ENet 1.3 client
  over `:gen_udp`, wire-compatible with stock enet 1.3.18 (verified
  against the `Melee.Transport.EnetNif` / `rusty_enet` oracle in
  `test/melee/transport/enet_beam_test.exs`).

  Implements exactly the subset Dolphin's Slippi spectator server
  exercises:

    * client-role connect handshake (`CONNECT` → `VERIFY_CONNECT` → ack),
      with `CONNECT` retransmission until the deadline
    * reliable receive on data channels: per-command acknowledgements,
      in-order delivery with duplicate suppression, and `SEND_FRAGMENT`
      reassembly (event payloads exceed the MTU)
    * reliable send of single-datagram packets with retransmission until
      acked (Slippi only needs the small JSON handshake)
    * keepalive `PING`s, acks for the server's pings, and disconnect
      detection via `DISCONNECT` commands or receive-silence timeout

  Events are delivered to the owner pid as the behaviour's messages,
  with this GenServer's pid as the connection handle. The owner is
  monitored; if it dies the connection is torn down (with a best-effort
  wire `DISCONNECT` so the server finds out immediately).

  Options accepted by `connect/4`:

    * `:connect_timeout` — ms to keep retrying `CONNECT` before giving up
      with `{:enet_disconnected, conn, :timeout}` (default 4000)
    * `:recv_timeout` — ms of receive silence before the connection is
      considered dead (default 5000; ENet peers ping every 500 ms, so a
      live server is never silent)
    * `:ping_interval` — ms between our keepalive pings (default 1000)

  Not implemented (out of scope for the Slippi client role): send-side
  fragmentation (`send/4` returns `{:error, :too_large}` above one MTU),
  unreliable/unsequenced sends, compression, checksums, bandwidth
  throttling, and server role.
  """

  @behaviour Melee.Transport

  use GenServer

  import Bitwise

  alias Melee.Transport.EnetBeam.{Channel, Protocol}

  @tick_ms 250
  @connect_resend_ms 500
  @default_connect_timeout_ms 4_000
  @default_recv_timeout_ms 5_000
  @default_ping_interval_ms 1_000
  @initial_rto_ms 500
  @max_send_attempts 8
  # MTU 1392 minus protocol header (4) and SEND_RELIABLE command (6).
  @max_payload 1_382

  ## Melee.Transport callbacks

  @doc """
  Open an ENet client connection to `host:port`, delivering events to
  `owner`. Returns `{:ok, conn}` once the `CONNECT` is on the wire;
  completion is signaled by `{:enet_connected, conn}` (or
  `{:enet_disconnected, conn, reason}`) sent to `owner`.
  """
  @impl Melee.Transport
  @spec connect(:inet.ip_address() | binary(), :inet.port_number(), pid(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def connect(host, port, owner, opts \\ []) do
    GenServer.start_link(__MODULE__, {host, port, owner, opts})
  end

  @doc """
  Send a reliable packet on `channel`. The packet must fit in one
  datagram (#{@max_payload} bytes) and `channel` must be within the
  server-negotiated channel count.
  """
  @impl Melee.Transport
  @spec send(pid(), Melee.Transport.channel(), binary(), :reliable) :: :ok | {:error, term()}
  def send(conn, channel, data, :reliable)
      when is_pid(conn) and channel in 0..255 and is_binary(data) do
    GenServer.call(conn, {:send, channel, data})
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc "Close the connection (best-effort wire `DISCONNECT`). Idempotent."
  @impl Melee.Transport
  @spec disconnect(pid()) :: :ok
  def disconnect(conn) when is_pid(conn) do
    GenServer.call(conn, :disconnect)
  catch
    :exit, _ -> :ok
  end

  ## GenServer callbacks

  @impl GenServer
  def init({host, port, owner, opts}) do
    with {:ok, ip} <- resolve(host),
         {:ok, socket} <- :gen_udp.open(0, [:binary, {:active, true}]),
         :ok <- :gen_udp.connect(socket, ip, port) do
      state = %{
        socket: socket,
        ip: ip,
        port: port,
        owner: owner,
        owner_ref: Process.monitor(owner),
        phase: :connecting,
        # Header addressing: 0xFFF/session 0 until VERIFY_CONNECT.
        remote_peer_id: Protocol.unassigned_peer_id(),
        session: 0,
        connect_id: :rand.uniform(0xFFFFFFFF),
        channel_count: 1,
        # Channel-0xFF outgoing reliable seq; 1 was consumed by CONNECT.
        seq_ff: 1,
        out_seq: %{},
        unacked: %{},
        channels: %{},
        connect_deadline: now_ms() + Keyword.get(opts, :connect_timeout, @default_connect_timeout_ms),
        recv_timeout: Keyword.get(opts, :recv_timeout, @default_recv_timeout_ms),
        ping_interval: Keyword.get(opts, :ping_interval, @default_ping_interval_ms),
        last_recv: now_ms(),
        last_ping: now_ms(),
        last_connect_send: 0
      }

      state = send_connect(state)
      Process.send_after(self(), :tick, @tick_ms)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send, channel, data}, _from, state) do
    cond do
      state.phase != :connected ->
        {:reply, {:error, :not_connected}, state}

      channel >= state.channel_count ->
        {:reply, {:error, :bad_channel}, state}

      byte_size(data) > @max_payload ->
        {:reply, {:error, :too_large}, state}

      true ->
        seq = (Map.get(state.out_seq, channel, 0) + 1) &&& 0xFFFF
        command = Protocol.send_reliable_command(channel, seq, data)
        transmit(state, command)

        entry = %{command: command, sent_at: now_ms(), rto: @initial_rto_ms, attempts: 1}

        state = %{
          state
          | out_seq: Map.put(state.out_seq, channel, seq),
            unacked: Map.put(state.unacked, {channel, seq}, entry)
        }

        {:reply, :ok, state}
    end
  end

  def handle_call(:disconnect, _from, state) do
    transmit(state, Protocol.disconnect_command())
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_info({:udp, socket, _ip, _port, datagram}, %{socket: socket} = state) do
    case Protocol.decode_packet(datagram) do
      {:ok, packet} ->
        state = %{state | last_recv: now_ms()}

        case handle_commands(packet, state) do
          {:cont, acks, state} ->
            flush_acks(state, acks)
            {:noreply, state}

          {:stop, acks, reason, state} ->
            flush_acks(state, acks)
            stop_disconnected(state, reason)
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:tick, state) do
    now = now_ms()

    result =
      cond do
        state.phase == :connecting and now >= state.connect_deadline ->
          {:stop, :timeout}

        state.phase == :connecting ->
          if now - state.last_connect_send >= @connect_resend_ms do
            {:cont, send_connect(state)}
          else
            {:cont, state}
          end

        now - state.last_recv >= state.recv_timeout ->
          {:stop, :timeout}

        true ->
          with {:cont, state} <- retransmit_unacked(state, now) do
            {:cont, maybe_ping(state, now)}
          end
      end

    case result do
      {:cont, state} ->
        Process.send_after(self(), :tick, @tick_ms)
        {:noreply, state}

      {:stop, reason} ->
        stop_disconnected(state, reason)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    transmit(state, Protocol.disconnect_command())
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_udp.close(state.socket)
    :ok
  end

  ## Internals — incoming commands

  # Process every command in a decoded packet, accumulating the acks it
  # owes. Returns {:cont, acks, state} or {:stop, acks, reason, state}.
  defp handle_commands(packet, state) do
    sent_time = packet.sent_time || 0

    Enum.reduce_while(packet.commands, {:cont, [], state}, fn command, {:cont, acks, state} ->
      case handle_command(command, sent_time, acks, state) do
        {:cont, _acks, _state} = result -> {:cont, result}
        {:stop, _acks, _reason, _state} = result -> {:halt, result}
      end
    end)
  end

  defp handle_command({:ack, channel, seq, _time}, _sent_time, acks, state),
    do: {:cont, acks, %{state | unacked: Map.delete(state.unacked, {channel, seq})}}

  defp handle_command({:verify_connect, seq, verify}, sent_time, acks, state) do
    if verify.connect_id == state.connect_id do
      acks = [Protocol.ack_command(0xFF, seq, sent_time) | acks]

      state =
        if state.phase == :connecting do
          Kernel.send(state.owner, {:enet_connected, self()})

          %{
            state
            | phase: :connected,
              remote_peer_id: verify.peer_id,
              session: verify.outgoing_session_id,
              channel_count: verify.channel_count
          }
        else
          # Duplicate VERIFY_CONNECT (our ack was lost): just re-ack.
          state
        end

      {:cont, acks, state}
    else
      {:cont, acks, state}
    end
  end

  defp handle_command({:ping, channel, seq}, sent_time, acks, state),
    do: {:cont, [Protocol.ack_command(channel, seq, sent_time) | acks], state}

  defp handle_command({:send_reliable, channel, seq, data}, sent_time, acks, state) do
    acks = [Protocol.ack_command(channel, seq, sent_time) | acks]
    {delivered, chan} = Channel.push_reliable(channel_state(state, channel), seq, data)
    {:cont, acks, deliver(state, channel, chan, delivered)}
  end

  defp handle_command({:send_fragment, channel, seq, fragment}, sent_time, acks, state) do
    acks = [Protocol.ack_command(channel, seq, sent_time) | acks]
    {delivered, chan} = Channel.push_fragment(channel_state(state, channel), fragment)
    {:cont, acks, deliver(state, channel, chan, delivered)}
  end

  defp handle_command({:send_unreliable, channel, data}, _sent_time, acks, state) do
    Kernel.send(state.owner, {:enet_packet, self(), channel, data})
    {:cont, acks, state}
  end

  defp handle_command({:send_unsequenced, channel, data}, _sent_time, acks, state) do
    Kernel.send(state.owner, {:enet_packet, self(), channel, data})
    {:cont, acks, state}
  end

  defp handle_command({:disconnect, seq, wants_ack?, _data}, sent_time, acks, state) do
    acks = if wants_ack?, do: [Protocol.ack_command(0xFF, seq, sent_time) | acks], else: acks
    {:stop, acks, :remote_disconnect, state}
  end

  # Commands we don't act on still need acking when sent reliably, or
  # the server retransmits them until it times the connection out.
  defp handle_command({:ignored, channel, seq, wants_ack?}, sent_time, acks, state) do
    acks = if wants_ack?, do: [Protocol.ack_command(channel, seq, sent_time) | acks], else: acks
    {:cont, acks, state}
  end

  defp channel_state(state, channel), do: Map.get(state.channels, channel, Channel.new())

  defp deliver(state, channel, chan, delivered) do
    Enum.each(delivered, &Kernel.send(state.owner, {:enet_packet, self(), channel, &1}))
    %{state | channels: Map.put(state.channels, channel, chan)}
  end

  ## Internals — outgoing

  # Wrap commands in a protocol header and put them on the wire.
  defp transmit(state, commands) do
    packet = Protocol.encode_packet(state.remote_peer_id, state.session, now_ms(), commands)
    :gen_udp.send(state.socket, state.ip, state.port, packet)
  end

  defp flush_acks(_state, []), do: :ok
  defp flush_acks(state, acks), do: transmit(state, Enum.reverse(acks))

  defp send_connect(state) do
    command = Protocol.connect_command(0, 1, state.connect_id, 1)
    transmit(state, command)
    %{state | last_connect_send: now_ms()}
  end

  defp maybe_ping(state, now) do
    if now - state.last_ping >= state.ping_interval do
      seq = state.seq_ff + 1 &&& 0xFFFF
      transmit(state, Protocol.ping_command(seq))
      %{state | seq_ff: seq, last_ping: now}
    else
      state
    end
  end

  # Resend overdue reliable commands with exponential backoff; give up
  # (and report :timeout) after @max_send_attempts tries on any command.
  defp retransmit_unacked(state, now) do
    overdue = for {key, e} <- state.unacked, now - e.sent_at >= e.rto, do: {key, e}

    if Enum.any?(overdue, fn {_key, e} -> e.attempts >= @max_send_attempts end) do
      {:stop, :timeout}
    else
      unacked =
        Enum.reduce(overdue, state.unacked, fn {key, e}, unacked ->
          transmit(state, e.command)
          Map.put(unacked, key, %{e | sent_at: now, rto: e.rto * 2, attempts: e.attempts + 1})
        end)

      {:cont, %{state | unacked: unacked}}
    end
  end

  defp stop_disconnected(state, reason) do
    Kernel.send(state.owner, {:enet_disconnected, self(), reason})
    {:stop, :normal, state}
  end

  ## Internals — misc

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp resolve(host) when is_tuple(host), do: {:ok, host}

  defp resolve(host) when is_binary(host),
    do: :inet.getaddr(String.to_charlist(host), :inet)
end
