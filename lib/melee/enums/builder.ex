defmodule Melee.Enums.Builder do
  @moduledoc false
  # Internal macro that generates integer-enum conversion functions from a
  # keyword list of `{atom_name, integer_id}` entries (in Python source order).
  #
  # Duplicate integer values are treated like Python `Enum` aliases: the
  # FIRST-defined name is canonical (returned by `from_id/1` and listed in
  # `entries/0`), while alias names are still accepted by `to_id/1`.

  defmacro int_enum(entries) do
    quote bind_quoted: [entries: entries] do
      @all_entries entries
      @canonical Enum.uniq_by(entries, fn {_name, id} -> id end)
      @from_id_map Map.new(@canonical, fn {name, id} -> {id, name} end)
      @to_id_map Map.new(@all_entries)

      @doc "Returns all canonical `{atom, id}` entries (aliases excluded)."
      @spec entries() :: [{atom(), integer()}]
      def entries, do: @canonical

      @doc """
      Converts a raw integer ID to its atom name.

      Unknown IDs return `{:unknown, id}` — this function never raises.
      """
      @spec from_id(integer()) :: atom() | {:unknown, integer()}
      def from_id(id) when is_integer(id), do: Map.get(@from_id_map, id, {:unknown, id})

      @doc """
      Converts an atom name (canonical or alias, or `{:unknown, id}`) to its
      raw integer ID. Raises `KeyError` for atoms that are not enum members.
      """
      @spec to_id(atom() | {:unknown, integer()}) :: integer()
      def to_id({:unknown, id}) when is_integer(id), do: id
      def to_id(name) when is_atom(name), do: Map.fetch!(@to_id_map, name)

      @doc "Returns true if the raw integer ID is a known enum member."
      @spec valid?(integer()) :: boolean()
      def valid?(id), do: is_integer(id) and Map.has_key?(@from_id_map, id)

      @doc """
      Returns a human-readable name for a raw integer ID.

      Unknown IDs return `"UNKNOWN(id)"`.
      """
      @spec name(integer()) :: String.t()
      def name(id) when is_integer(id) do
        case Map.get(@from_id_map, id) do
          nil -> "UNKNOWN(#{id})"
          atom -> atom |> Atom.to_string() |> String.upcase()
        end
      end
    end
  end
end
