defmodule Melee.ShiftJIS do
  @moduledoc """
  Minimal Shift-JIS decoding for Slippi name fields.

  Slippi stores display names, connect codes, and in-game nametags as
  null-terminated Shift-JIS. Melee nametags are written in FULL-WIDTH
  characters (`Ｅ Ｘ Ｐ Ｈ`), which the Slippi spec describes as
  "convertible to ASCII" — this module folds full-width alphanumerics,
  space, and `＃` down to their ASCII equivalents, so a nametag reads
  back as `"EXPH"` rather than mojibake.

  Other double-byte characters (kana, kanji) are preserved as `?`
  placeholders rather than dropped, so string lengths stay stable.
  """

  @doc """
  Decode a null-terminated Shift-JIS string starting at `offset`.

  Returns `""` when the offset is out of range.

  ## Examples

      iex> Melee.ShiftJIS.read(<<"ABC", 0, "junk">>, 0)
      "ABC"

      iex> Melee.ShiftJIS.read(<<"EXPH", 0x81, 0x94, "288", 0>>, 0)
      "EXPH#288"

      iex> # a Melee nametag: full-width Ｅ Ｘ Ｐ Ｈ
      iex> Melee.ShiftJIS.read(<<0x82, 0x64, 0x82, 0x77, 0x82, 0x6F, 0x82, 0x67, 0>>, 0)
      "EXPH"
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
  # Full-width space.
  defp decode(<<0x81, 0x40, rest::binary>>, acc), do: decode(rest, [?\s | acc])

  # Full-width alphanumerics (Melee nametags) folded to ASCII.
  defp decode(<<0x82, c, rest::binary>>, acc) when c in 0x4F..0x58,
    do: decode(rest, [?0 + (c - 0x4F) | acc])

  defp decode(<<0x82, c, rest::binary>>, acc) when c in 0x60..0x79,
    do: decode(rest, [?A + (c - 0x60) | acc])

  defp decode(<<0x82, c, rest::binary>>, acc) when c in 0x81..0x9A,
    do: decode(rest, [?a + (c - 0x81) | acc])

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
