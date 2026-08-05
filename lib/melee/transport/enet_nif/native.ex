defmodule Melee.Transport.EnetNif.Native do
  @moduledoc """
  Raw NIF bindings for the `melee_enet` Rustler crate (a thin wrapper over
  `rusty_enet`, jabuwu's pure-Rust ENet 1.3 port).

  A resource is an opaque handle to an ENet host — either a client host
  created by `host_connect/2` or a listening server host created by
  `host_listen/1` (test support for loopback tests and the future
  `Melee.Transport.EnetBeam` cross-compat tests).

  Most callers should use `Melee.Transport.EnetNif` instead; these
  functions are the low-level building blocks it drives.
  """

  use Rustler, otp_app: :libmelee_ex, crate: "melee_enet"

  @typedoc "Opaque NIF resource holding an ENet host."
  @type resource :: reference()

  @typedoc "An event drained by `host_service/2`."
  @type event ::
          :connected
          | {:disconnected, atom()}
          | {:packet, Melee.Transport.channel(), binary()}

  @doc """
  Create a 1-channel ENet client host and initiate a connect handshake to
  `address:port`. Returns immediately; completion arrives as a
  `:connected` (or `{:disconnected, reason}`) event from `host_service/2`.
  """
  @spec host_connect(String.t(), :inet.port_number()) ::
          {:ok, resource()} | {:error, term()}
  def host_connect(_address, _port), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Create a listening ENet server host on 127.0.0.1:`port` (0 picks an
  ephemeral port — read it back with `host_port/1`). Test support.
  """
  @spec host_listen(:inet.port_number()) :: {:ok, resource()} | {:error, term()}
  def host_listen(_port), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Local UDP port the host's socket is bound to."
  @spec host_port(resource()) :: {:ok, :inet.port_number()} | {:error, term()}
  def host_port(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Service the host, draining all currently-available events. Returns as
  soon as at least one event is available, or `{:ok, []}` once
  `timeout_ms` elapses. Blocks (dirty IO scheduler); safe to call while
  other processes call `peer_send/3` or `host_destroy/1` on the same
  resource.
  """
  @spec host_service(resource(), non_neg_integer()) ::
          {:ok, [event()]} | {:error, term()}
  def host_service(_resource, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Send a reliable packet on `channel` to the first connected peer, and
  flush so it hits the wire immediately.
  """
  @spec peer_send(resource(), Melee.Transport.channel(), binary()) ::
          :ok | {:error, term()}
  def peer_send(_resource, _channel, _data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Send a reliable packet from a server host to its first connected peer.
  Same mechanics as `peer_send/3`; named separately for test readability.
  """
  @spec server_send(resource(), Melee.Transport.channel(), binary()) ::
          :ok | {:error, term()}
  def server_send(resource, channel, data), do: peer_send(resource, channel, data)

  @doc """
  Disconnect any connected peers (notifying the remote side), then drop
  the host and close its socket. Idempotent.
  """
  @spec host_destroy(resource()) :: :ok
  def host_destroy(_resource), do: :erlang.nif_error(:nif_not_loaded)
end
