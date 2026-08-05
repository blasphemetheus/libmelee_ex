defmodule Melee.Transport do
  @moduledoc """
  Behaviour for ENet transports connecting to a Slippi Dolphin instance.

  Dolphin's Slippi spectator server speaks ENet (reliable UDP) on
  localhost port 51441. A transport implementation owns that connection
  and pushes events to an owner process as messages:

    * `{:enet_connected, conn}` — the ENet connect handshake completed
    * `{:enet_packet, conn, channel, binary}` — a packet arrived
    * `{:enet_disconnected, conn, reason}` — the peer disconnected or
      the connection timed out

  Two implementations are provided:

    * `Melee.Transport.EnetNif` — Rustler NIF over the `rusty_enet` crate
    * `Melee.Transport.EnetBeam` — BEAM-native ENet protocol implementation

  Only the small subset of ENet that Dolphin's spectator peer exercises is
  required: client-role connect handshake, a single channel (0), reliable
  send/receive including fragment reassembly (gecko code lists exceed the
  MTU), ping handling, and disconnect detection.
  """

  @typedoc "Opaque transport connection handle."
  @type conn :: term()

  @typedoc "ENet channel id. The Slippi spectator protocol uses channel 0."
  @type channel :: 0..255

  @doc """
  Open an ENet connection to `host:port`, delivering events to `owner`.

  Returns once the connection attempt is initiated; completion is signaled
  by an `{:enet_connected, conn}` (or `{:enet_disconnected, conn, reason}`)
  message to `owner`.
  """
  @callback connect(
              host :: :inet.ip_address() | binary(),
              port :: :inet.port_number(),
              owner :: pid(),
              opts :: keyword()
            ) :: {:ok, conn()} | {:error, term()}

  @doc "Send a reliable packet on the given channel."
  @callback send(conn(), channel(), data :: binary(), mode :: :reliable) ::
              :ok | {:error, term()}

  @doc "Close the connection and release its resources."
  @callback disconnect(conn()) :: :ok
end
