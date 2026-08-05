defmodule Melee.ShiftJIS do
  @moduledoc """
  Minimal Shift-JIS decoding for Slippi name fields.

  Slippi stores display names and connect codes as null-terminated
  Shift-JIS. Connect codes are ASCII plus the full-width `＃` (0x81 0x94),
  which libmelee normalizes to `#`. This module decodes ASCII and the
  handful of full-width forms that appear in connect codes exactly;
  other double-byte characters are preserved as `?` placeholders rather
  than dropped, so string lengths stay stable.
  """

  @doc """
  Decode a null-terminated Shift-JIS string starting at `offset`.

  Returns `""` when the offset is out of range.

  ## Examples

      iex> Melee.ShiftJIS.read(<<"ABC", 0, "junk">>, 0)
      "ABC"

      iex> Melee.ShiftJIS.read(<<"EXPH", 0x81, 0x94, "288", 0>>, 0)
      "EXPH#288"
  """
  @spec read(binary(), non_neg_integer()) :: String.t()
  def read(bin, offset) when offset < byte_size(bin) do
    bin
    |> binary_part(offset, byte_size(bin) - offset)
    |> take_until_null()
    |> decode([])
  end

  def read(_bin, _offset), do: ""

  defp take_until_null(bin) do
    case :binary.match(bin, <<0>>) do
      {idx, _} -> binary_part(bin, 0, idx)
      :nomatch -> bin
    end
  end

  # Full-width hash used in connect codes; libmelee replaces it with '#'.
  defp decode(<<0x81, 0x94, rest::binary>>, acc), do: decode(rest, [?# | acc])
  # ASCII passes through.
  defp decode(<<c, rest::binary>>, acc) when c < 0x80, do: decode(rest, [c | acc])
  # Any other Shift-JIS lead byte starts a double-byte character.
  defp decode(<<lead, _trail, rest::binary>>, acc)
       when lead in 0x81..0x9F or lead in 0xE0..0xFC,
       do: decode(rest, [?? | acc])

  # Half-width katakana or stray byte: single byte, placeholder.
  defp decode(<<_c, rest::binary>>, acc), do: decode(rest, [?? | acc])
  defp decode(<<>>, acc), do: acc |> Enum.reverse() |> List.to_string()
end
