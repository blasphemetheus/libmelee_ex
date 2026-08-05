defmodule Melee.FrameData do
  @moduledoc """
  Static per-character frame data compiled from libmelee's CSV tables.

  Two tables are loaded at compile time from `priv/`:

    * `actiondata.csv` — which (character, action) pairs report their
      animation frame zero-indexed in Slippi. libmelee (and this port)
      normalizes those to 1-indexed in `Melee.PlayerState.action_frame`.
    * `characterdata.csv` — physics constants per character (gravity,
      friction, air speed, ...).
  """

  @external_resource actiondata_path = Path.join(__DIR__, "../../priv/actiondata.csv")
  @external_resource characterdata_path = Path.join(__DIR__, "../../priv/characterdata.csv")

  parse_csv = fn path ->
    [header | rows] =
      path
      |> File.read!()
      |> String.split(["\r\n", "\n"], trim: true)

    split = fn line ->
      line
      |> String.split(",")
      |> Enum.map(&String.trim(&1, "\""))
    end

    keys = split.(header)
    Enum.map(rows, fn row -> Enum.zip(keys, split.(row)) |> Map.new() end)
  end

  @zero_indices actiondata_path
                |> parse_csv.()
                |> Enum.filter(&(&1["zeroindex"] == "True"))
                |> Enum.group_by(
                  &String.to_integer(&1["character"]),
                  &String.to_integer(&1["action"])
                )
                |> Map.new(fn {char, actions} -> {char, MapSet.new(actions)} end)

  @characterdata characterdata_path
                 |> parse_csv.()
                 |> Map.new(fn row ->
                   {name, row} = Map.pop(row, "Character")
                   index = String.to_integer(row["CharacterIndex"])

                   numeric =
                     Map.new(row, fn {k, v} ->
                       case Float.parse(v) do
                         {f, ""} -> {k, f}
                         _ -> {k, v}
                       end
                     end)

                   {index, Map.put(numeric, "Character", name)}
                 end)

  @doc """
  Does the given (character, action) pair report zero-indexed animation
  frames in the Slippi stream?

  ## Examples

      iex> Melee.FrameData.zero_indexed?(22, 323)
      true

      iex> Melee.FrameData.zero_indexed?(22, 322)
      false
  """
  @spec zero_indexed?(integer(), integer()) :: boolean()
  def zero_indexed?(character, action) do
    case Map.fetch(@zero_indices, character) do
      {:ok, actions} -> MapSet.member?(actions, action)
      :error -> false
    end
  end

  @doc "Physics constants for a character (by in-game character index), or nil."
  @spec character_data(integer()) :: map() | nil
  def character_data(character_index), do: Map.get(@characterdata, character_index)
end
