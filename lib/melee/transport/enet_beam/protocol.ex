defmodule Melee.Transport.EnetBeam.Protocol do
  @moduledoc """
  Pure encode/decode for the client-side subset of the ENet 1.3 wire
  protocol (as spoken by stock enet 1.3.18 / `rusty_enet` 0.4).

  Wire facts sourced from `enet/protocol.c` (via the `rusty_enet`
  transpile, the same code the `Melee.Transport.EnetNif` oracle runs):

    * Protocol header is a big-endian `peerID` u16 with flags packed into
      the high bits: bit 15 = sent-time present, bit 14 = compressed,
      bits 13..12 = session id, bits 11..0 = peer id. When the sent-time
      flag is set a u16 `sentTime` follows.
    * Every packet that carries an acknowledge-flagged (reliable) command
      MUST set the sent-time flag — receivers drop the remainder of the
      packet otherwise.
    * Before `VERIFY_CONNECT` assigns us a peer id, packets are addressed
      to peer id `0xFFF` with zero session bits.
    * Command header: `command` u8 (bit 7 = wants-ack, bit 6 =
      unsequenced, low nibble = command number), `channelID` u8,
      `reliableSequenceNumber` u16.
    * An `ACKNOWLEDGE` echoes the acked command's sequence number (in
      both its own header and payload), its channel id, and the sent time
      of the packet that carried it.

  All multi-byte integers are big-endian. No compression, no checksum
  (matching the oracle host configuration and Dolphin's Slippi server).
  """

  import Bitwise

  @flag_ack 0x80
  @flag_unsequenced 0x40

  @header_flag_sent_time 0x8000
  @max_peer_id 0xFFF

  @cmd_ack 1
  @cmd_connect 2
  @cmd_verify_connect 3
  @cmd_disconnect 4
  @cmd_ping 5
  @cmd_send_reliable 6
  @cmd_send_unreliable 7
  @cmd_send_fragment 8
  @cmd_send_unsequenced 9
  @cmd_bandwidth_limit 10
  @cmd_throttle_configure 11
  @cmd_send_unreliable_fragment 12

  @typedoc "16-bit reliable sequence number."
  @type seq :: 0..0xFFFF

  @typedoc "A decoded ENet protocol command."
  @type command ::
          {:ack, Melee.Transport.channel() | 0xFF, seq(), sent_time :: 0..0xFFFF}
          | {:verify_connect, seq(), map()}
          | {:disconnect, seq(), wants_ack? :: boolean(), data :: non_neg_integer()}
          | {:ping, Melee.Transport.channel() | 0xFF, seq()}
          | {:send_reliable, Melee.Transport.channel(), seq(), binary()}
          | {:send_unreliable, Melee.Transport.channel(), binary()}
          | {:send_unsequenced, Melee.Transport.channel(), binary()}
          | {:send_fragment, Melee.Transport.channel(), seq(), map()}
          | {:ignored, 0..0xFF, seq(), wants_ack? :: boolean()}

  @typedoc "A decoded ENet datagram."
  @type packet :: %{
          peer_id: 0..0xFFF,
          session: 0..3,
          sent_time: 0..0xFFFF | nil,
          commands: [command()]
        }

  ## Decoding

  @doc """
  Decode one UDP datagram into its protocol header and command list.

  Unknown or malformed trailing commands end the command list (mirroring
  the C implementation, which stops parsing at the first bad command).
  Compressed packets are rejected (`:error`) — we never negotiate
  compression.

  ## Examples

      iex> alias Melee.Transport.EnetBeam.Protocol
      iex> pkt = Protocol.encode_packet(7, 2, 1234, [Protocol.ping_command(9)])
      iex> {:ok, decoded} = Protocol.decode_packet(IO.iodata_to_binary(pkt))
      iex> {decoded.peer_id, decoded.session, decoded.sent_time, decoded.commands}
      {7, 2, 1234, [{:ping, 0xFF, 9}]}
  """
  @spec decode_packet(binary()) :: {:ok, packet()} | :error
  def decode_packet(<<peer_field::16, rest::binary>>) do
    compressed? = (peer_field &&& 0x4000) != 0
    sent_time? = (peer_field &&& @header_flag_sent_time) != 0

    cond do
      compressed? ->
        :error

      sent_time? ->
        case rest do
          <<sent_time::16, body::binary>> ->
            {:ok, header_map(peer_field, sent_time, body)}

          _ ->
            :error
        end

      true ->
        {:ok, header_map(peer_field, nil, rest)}
    end
  end

  def decode_packet(_other), do: :error

  defp header_map(peer_field, sent_time, body) do
    %{
      peer_id: peer_field &&& @max_peer_id,
      session: peer_field >>> 12 &&& 0x3,
      sent_time: sent_time,
      commands: decode_commands(body, [])
    }
  end

  defp decode_commands(<<cmd_byte::8, channel::8, seq::16, rest::binary>>, acc) do
    number = cmd_byte &&& 0x0F
    wants_ack? = (cmd_byte &&& @flag_ack) != 0

    case decode_command(number, channel, seq, wants_ack?, rest) do
      {command, more} -> decode_commands(more, [command | acc])
      :halt -> Enum.reverse(acc)
    end
  end

  defp decode_commands(_short, acc), do: Enum.reverse(acc)

  defp decode_command(
         @cmd_ack,
         channel,
         _seq,
         _ack?,
         <<recv_seq::16, recv_time::16, rest::binary>>
       ),
       do: {{:ack, channel, recv_seq, recv_time}, rest}

  defp decode_command(@cmd_verify_connect, _channel, seq, _ack?, <<
         peer_id::16,
         incoming_session_id::8,
         outgoing_session_id::8,
         mtu::32,
         window_size::32,
         channel_count::32,
         _incoming_bw::32,
         _outgoing_bw::32,
         _throttle_interval::32,
         _throttle_accel::32,
         _throttle_decel::32,
         connect_id::32,
         rest::binary
       >>) do
    verify = %{
      peer_id: peer_id,
      incoming_session_id: incoming_session_id,
      outgoing_session_id: outgoing_session_id,
      mtu: mtu,
      window_size: window_size,
      channel_count: channel_count,
      connect_id: connect_id
    }

    {{:verify_connect, seq, verify}, rest}
  end

  defp decode_command(@cmd_disconnect, _channel, seq, ack?, <<data::32, rest::binary>>),
    do: {{:disconnect, seq, ack?, data}, rest}

  defp decode_command(@cmd_ping, channel, seq, _ack?, rest),
    do: {{:ping, channel, seq}, rest}

  defp decode_command(@cmd_send_reliable, channel, seq, _ack?, <<
         len::16,
         data::binary-size(len),
         rest::binary
       >>),
       do: {{:send_reliable, channel, seq, data}, rest}

  defp decode_command(@cmd_send_unreliable, channel, _seq, _ack?, <<
         _unreliable_seq::16,
         len::16,
         data::binary-size(len),
         rest::binary
       >>),
       do: {{:send_unreliable, channel, data}, rest}

  defp decode_command(@cmd_send_unsequenced, channel, _seq, _ack?, <<
         _group::16,
         len::16,
         data::binary-size(len),
         rest::binary
       >>),
       do: {{:send_unsequenced, channel, data}, rest}

  defp decode_command(@cmd_send_fragment, channel, seq, _ack?, <<
         start_seq::16,
         len::16,
         fragment_count::32,
         fragment_number::32,
         total_length::32,
         fragment_offset::32,
         data::binary-size(len),
         rest::binary
       >>) do
    fragment = %{
      start: start_seq,
      count: fragment_count,
      number: fragment_number,
      total: total_length,
      offset: fragment_offset,
      data: data
    }

    {{:send_fragment, channel, seq, fragment}, rest}
  end

  # Commands a Slippi client never acts on (e.g. the reliable
  # THROTTLE_CONFIGURE / BANDWIDTH_LIMIT the server's bandwidth throttle
  # emits every second): skipped by their fixed sizes so later commands
  # still parse, but channel/seq/ack-flag are preserved so reliable ones
  # can be acknowledged — an unacked reliable command is retransmitted
  # forever and eventually times the connection out.
  defp decode_command(@cmd_connect, c, s, a, <<_::binary-size(44), rest::binary>>),
    do: {{:ignored, c, s, a}, rest}

  defp decode_command(@cmd_bandwidth_limit, c, s, a, <<_::binary-size(8), rest::binary>>),
    do: {{:ignored, c, s, a}, rest}

  defp decode_command(@cmd_throttle_configure, c, s, a, <<_::binary-size(12), rest::binary>>),
    do: {{:ignored, c, s, a}, rest}

  defp decode_command(@cmd_send_unreliable_fragment, c, s, a, <<
         _start::16,
         len::16,
         _rest_of_fields::binary-size(16),
         _data::binary-size(len),
         rest::binary
       >>),
       do: {{:ignored, c, s, a}, rest}

  defp decode_command(_number, _channel, _seq, _ack?, _rest), do: :halt

  ## Encoding

  @doc """
  Encode a datagram addressed to `peer_id` with the given session bits.

  The sent-time flag is always set (required whenever a reliable command
  is aboard, harmless otherwise). Pass `peer_id` `0xFFF` and `session` 0
  before `VERIFY_CONNECT` has assigned us an id.
  """
  @spec encode_packet(0..0xFFF, 0..3, 0..0xFFFF, iodata()) :: iodata()
  def encode_packet(peer_id, session, sent_time, commands) do
    field = peer_id ||| session <<< 12 ||| @header_flag_sent_time
    time = sent_time &&& 0xFFFF
    [<<field::16, time::16>>, commands]
  end

  @doc "Peer id used in headers before the server assigns one."
  @spec unassigned_peer_id() :: 0xFFF
  def unassigned_peer_id, do: @max_peer_id

  @doc """
  Encode a `CONNECT` command (channel `0xFF`, reliable) advertising
  ourselves as peer `local_peer_id` with `channel_count` channels.

  Defaults mirror `enet_host_connect` with unlimited bandwidth:
  MTU 1392, window 65536, throttle 5000/2/2, session ids `0xFF`
  ("server picks"), user data 0.
  """
  @spec connect_command(0..0xFFF, seq(), non_neg_integer(), pos_integer()) :: binary()
  def connect_command(local_peer_id, seq, connect_id, channel_count) do
    <<@cmd_connect ||| @flag_ack, 0xFF, seq::16, local_peer_id::16, 0xFF, 0xFF, 1392::32,
      65_536::32, channel_count::32, 0::32, 0::32, 5000::32, 2::32, 2::32, connect_id::32, 0::32>>
  end

  @doc """
  Encode an `ACKNOWLEDGE` for a reliable command received with sequence
  number `seq` on `channel`, echoing the carrying packet's `sent_time`.
  """
  @spec ack_command(0..0xFF, seq(), 0..0xFFFF) :: binary()
  def ack_command(channel, seq, sent_time),
    do: <<@cmd_ack, channel, seq::16, seq::16, sent_time::16>>

  @doc "Encode a reliable `PING` on channel `0xFF`."
  @spec ping_command(seq()) :: binary()
  def ping_command(seq), do: <<@cmd_ping ||| @flag_ack, 0xFF, seq::16>>

  @doc "Encode a reliable `SEND_RELIABLE` data command."
  @spec send_reliable_command(Melee.Transport.channel(), seq(), binary()) :: binary()
  def send_reliable_command(channel, seq, data),
    do: <<@cmd_send_reliable ||| @flag_ack, channel, seq::16, byte_size(data)::16, data::binary>>

  @doc """
  Encode an unsequenced `DISCONNECT` (the `enet_peer_disconnect_now`
  shape: fire-and-forget, no ack expected).
  """
  @spec disconnect_command(non_neg_integer()) :: binary()
  def disconnect_command(data \\ 0),
    do: <<@cmd_disconnect ||| @flag_unsequenced, 0xFF, 0::16, data::32>>
end
