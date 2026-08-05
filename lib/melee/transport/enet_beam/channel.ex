defmodule Melee.Transport.EnetBeam.Channel do
  @moduledoc """
  Pure receive-side state for one ENet channel: reliable in-order
  delivery, duplicate suppression, and `SEND_FRAGMENT` reassembly.

  ENet reliable sequence numbers are 16-bit and wrap; a sequence number
  is "old" (already delivered / duplicate) when its forward distance from
  the next expected number is `>= 0x8000`. Fragments of one packet occupy
  consecutive sequence numbers starting at the group's
  `startSequenceNumber`; the whole group is delivered once complete and
  its start is the next expected number, after which the expected number
  advances by the fragment count.
  """

  import Bitwise

  alias Melee.Transport.EnetBeam.Channel

  defstruct next: 1, pending: %{}, frags: %{}

  @typedoc "Receive-side channel state."
  @type t :: %Channel{
          next: 0..0xFFFF,
          pending: %{optional(0..0xFFFF) => binary()},
          frags: %{optional(0..0xFFFF) => map()}
        }

  @doc "Fresh channel state (first expected reliable sequence number is 1)."
  @spec new() :: t()
  def new, do: %Channel{}

  @doc """
  Accept a `SEND_RELIABLE` payload with sequence number `seq`.

  Returns `{deliverable_payloads_in_order, updated_channel}`; the list is
  empty when the packet was a duplicate or arrived ahead of a gap.

  ## Examples

      iex> alias Melee.Transport.EnetBeam.Channel
      iex> chan = Channel.new()
      iex> {[], chan} = Channel.push_reliable(chan, 2, "b")
      iex> {delivered, _chan} = Channel.push_reliable(chan, 1, "a")
      iex> delivered
      ["a", "b"]
  """
  @spec push_reliable(t(), 0..0xFFFF, binary()) :: {[binary()], t()}
  def push_reliable(%Channel{} = chan, seq, data) do
    if old?(chan, seq) or Map.has_key?(chan.pending, seq) do
      {[], chan}
    else
      drain(%{chan | pending: Map.put(chan.pending, seq, data)})
    end
  end

  @doc """
  Accept one `SEND_FRAGMENT` piece (the map decoded by
  `Melee.Transport.EnetBeam.Protocol`: `start`, `count`, `number`,
  `total`, `offset`, `data`).

  Returns `{deliverable_payloads_in_order, updated_channel}`; the
  reassembled packet is delivered once every fragment of the group has
  arrived and the group is next in sequence.
  """
  @spec push_fragment(t(), map()) :: {[binary()], t()}
  def push_fragment(%Channel{} = chan, %{start: start, number: number} = frag) do
    group =
      Map.get(chan.frags, start, %{count: frag.count, total: frag.total, parts: %{}})

    cond do
      old?(chan, start) or Map.has_key?(group.parts, number) ->
        {[], chan}

      true ->
        parts = Map.put(group.parts, number, {frag.offset, frag.data})
        drain(%{chan | frags: Map.put(chan.frags, start, %{group | parts: parts})})
    end
  end

  ## Internals

  # Forward distance >= 0x8000 means seq is behind the expected number.
  defp old?(%Channel{next: next}, seq), do: (seq - next &&& 0xFFFF) >= 0x8000

  # Deliver everything now contiguous at the head of the sequence space.
  defp drain(chan), do: drain(chan, [])

  defp drain(%Channel{next: next} = chan, acc) do
    cond do
      Map.has_key?(chan.pending, next) ->
        {data, pending} = Map.pop(chan.pending, next)
        drain(%{chan | pending: pending, next: bump(next, 1)}, [data | acc])

      complete_group?(chan.frags[next]) ->
        {group, frags} = Map.pop(chan.frags, next)
        chan = %{chan | frags: frags, next: bump(next, group.count)}

        case assemble(group) do
          {:ok, data} -> drain(chan, [data | acc])
          :error -> drain(chan, acc)
        end

      true ->
        {Enum.reverse(acc), chan}
    end
  end

  defp bump(seq, by), do: seq + by &&& 0xFFFF

  defp complete_group?(nil), do: false
  defp complete_group?(group), do: map_size(group.parts) == group.count

  # Concatenate fragments by offset; reject if sizes do not tile exactly.
  defp assemble(%{total: total, parts: parts}) do
    data =
      parts
      |> Map.values()
      |> Enum.sort_by(fn {offset, _data} -> offset end)
      |> Enum.map(fn {_offset, data} -> data end)
      |> IO.iodata_to_binary()

    if byte_size(data) == total, do: {:ok, data}, else: :error
  end
end
