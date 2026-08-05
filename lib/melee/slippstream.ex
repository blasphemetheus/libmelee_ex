defmodule Melee.Slippstream do
  @moduledoc """
  Codec for the Slippi spectator ("Slippstream") message protocol.

  Every ENet packet exchanged with Dolphin's spectator server (port
  51441) is a JSON document. The client sends exactly one message — the
  connect request — and receives:

    * `connect_reply` — nick, version, cursor
    * `game_event` — base64-encoded raw Slippi event bytes
    * `menu_event` — base64-encoded menu event bytes
    * `frame_end` — pre-3.0 SLP "manual bookend" marker

  This module only translates between packets and typed messages; the
  binary payloads inside go to `Melee.Events`.
  """

  @type message ::
          {:connect_reply, %{nick: String.t(), version: String.t(), cursor: integer()}}
          | {:game_event, binary()}
          | {:menu_event, binary()}
          | :frame_end
          | {:unknown, map()}

  @doc """
  The connect-request packet sent (reliably) after the ENet handshake.

  ## Examples

      iex> Melee.Slippstream.connect_request()
      ~S({"cursor":0,"type":"connect_request"})
  """
  @spec connect_request() :: binary()
  def connect_request do
    Jason.encode!(%{"type" => "connect_request", "cursor" => 0})
  end

  @doc """
  Decode one inbound packet into a typed message.

  Payloads are base64-decoded here; empty payloads decode to `<<>>`
  (Dolphin sends zero-length game events at game end).

  ## Examples

      iex> Melee.Slippstream.decode(~S({"type":"game_event","payload":"NgMQ"}))
      {:ok, {:game_event, <<0x36, 0x03, 0x10>>}}

      iex> Melee.Slippstream.decode(
      ...>   ~S({"type":"connect_reply","nick":"Slippi","version":"3.4.0","cursor":1}))
      {:ok, {:connect_reply, %{nick: "Slippi", version: "3.4.0", cursor: 1}}}

      iex> Melee.Slippstream.decode("not json")
      {:error, :invalid_json}
  """
  @spec decode(binary()) :: {:ok, message()} | {:error, term()}
  def decode(packet) when is_binary(packet) do
    case Jason.decode(packet) do
      {:ok, %{"type" => "connect_reply"} = msg} ->
        {:ok,
         {:connect_reply,
          %{
            nick: Map.get(msg, "nick", ""),
            version: Map.get(msg, "version", ""),
            cursor: Map.get(msg, "cursor", 0)
          }}}

      {:ok, %{"type" => "game_event"} = msg} ->
        decode_payload(msg, :game_event)

      {:ok, %{"type" => "menu_event"} = msg} ->
        decode_payload(msg, :menu_event)

      {:ok, %{"type" => "frame_end"}} ->
        {:ok, :frame_end}

      {:ok, msg} when is_map(msg) ->
        {:ok, {:unknown, msg}}

      {:ok, _other} ->
        {:error, :invalid_message}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp decode_payload(msg, tag) do
    case Base.decode64(Map.get(msg, "payload", "")) do
      {:ok, payload} -> {:ok, {tag, payload}}
      :error -> {:error, {:invalid_payload, tag}}
    end
  end
end
