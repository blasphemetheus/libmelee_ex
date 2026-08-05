defmodule Melee.Transport.EnetNif do
  @moduledoc """
  `Melee.Transport` implementation backed by a Rustler NIF over the
  `rusty_enet` crate (pure-Rust ENet 1.3).

  `connect/4` starts a GenServer (linked to the caller) that owns the
  ENet host resource and pumps it: it repeatedly calls the dirty-IO
  `host_service` NIF and forwards every drained event to the owner pid as
  the behaviour's messages, with the GenServer pid as the connection
  handle:

    * `{:enet_connected, conn}`
    * `{:enet_packet, conn, channel, binary}`
    * `{:enet_disconnected, conn, reason}`

  The service loop runs via self-sent `:service` messages (not
  `handle_continue`) so `send/4` and `disconnect/1` calls interleave with
  the blocking NIF between iterations; each iteration blocks at most
  `:service_timeout` ms (default #{100}). The owner is monitored — if it
  dies, the host is destroyed and the GenServer stops. A remote
  disconnect (or connect timeout) is forwarded and then terminates the
  GenServer.
  """

  @behaviour Melee.Transport

  use GenServer

  alias Melee.Transport.EnetNif.Native

  @default_service_timeout_ms 100

  ## Melee.Transport callbacks

  @doc """
  Open an ENet client connection to `host:port`, delivering events to
  `owner`. Returns `{:ok, conn}` once the connection attempt is
  initiated; completion is signaled by `{:enet_connected, conn}` (or
  `{:enet_disconnected, conn, reason}`) sent to `owner`.

  Options:

    * `:service_timeout` — max ms each service-loop iteration blocks
      (default #{@default_service_timeout_ms}); bounds the latency of
      `send/4` / `disconnect/1` calls.
  """
  @impl Melee.Transport
  @spec connect(:inet.ip_address() | binary(), :inet.port_number(), pid(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def connect(host, port, owner, opts \\ []) do
    GenServer.start_link(__MODULE__, {host_to_string(host), port, owner, opts})
  end

  @doc "Send a reliable packet on `channel` over the connection."
  @impl Melee.Transport
  @spec send(pid(), Melee.Transport.channel(), binary(), :reliable) ::
          :ok | {:error, term()}
  def send(conn, channel, data, :reliable)
      when is_pid(conn) and channel in 0..255 and is_binary(data) do
    GenServer.call(conn, {:send, channel, data})
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc "Close the connection and release the ENet host. Idempotent."
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
    case Native.host_connect(host, port) do
      {:ok, res} ->
        owner_ref = Process.monitor(owner)
        Kernel.send(self(), :service)

        {:ok,
         %{
           res: res,
           owner: owner,
           owner_ref: owner_ref,
           service_timeout:
             Keyword.get(opts, :service_timeout, @default_service_timeout_ms)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info(:service, state) do
    case Native.host_service(state.res, state.service_timeout) do
      {:ok, events} ->
        case forward_events(events, state) do
          :cont ->
            Kernel.send(self(), :service)
            {:noreply, state}

          :disconnected ->
            {:stop, :normal, state}
        end

      {:error, reason} ->
        notify_disconnected(state, reason)
        {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    Native.host_destroy(state.res)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:send, channel, data}, _from, state) do
    {:reply, Native.peer_send(state.res, channel, data), state}
  end

  def handle_call(:disconnect, _from, state) do
    Native.host_destroy(state.res)
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Native.host_destroy(state.res)
    :ok
  end

  ## Internals

  # Forward drained NIF events to the owner as behaviour messages.
  # Returns :disconnected if a disconnect was seen (loop must stop).
  defp forward_events(events, state) do
    Enum.reduce(events, :cont, fn event, acc ->
      case event do
        :connected ->
          Kernel.send(state.owner, {:enet_connected, self()})
          acc

        {:packet, channel, data} ->
          Kernel.send(state.owner, {:enet_packet, self(), channel, data})
          acc

        {:disconnected, reason} ->
          notify_disconnected(state, reason)
          :disconnected
      end
    end)
  end

  defp notify_disconnected(state, reason) do
    Native.host_destroy(state.res)
    Kernel.send(state.owner, {:enet_disconnected, self(), reason})
  end

  defp host_to_string(host) when is_binary(host), do: host

  defp host_to_string(host) when is_tuple(host) do
    host |> :inet.ntoa() |> List.to_string()
  end
end
