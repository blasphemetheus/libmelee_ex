defmodule Melee.MemoryMapTest do
  use ExUnit.Case, async: true

  alias Melee.{MemoryMap, MemoryWatcher}

  test "menu set: unique names, well-formed hex lines, expected count" do
    watches = MemoryMap.menu()
    names = Keyword.keys(watches)
    assert length(names) == length(Enum.uniq(names))
    # 6 globals + 5 fields x 4 ports
    assert length(watches) == 26

    for {_name, line} <- watches do
      # Every space-separated token must parse as hex (Dolphin's
      # ParseLine does `stringstream >> hex`).
      for token <- String.split(line) do
        assert {_, ""} = Integer.parse(token, 16), "bad token #{token} in #{line}"
      end
    end
  end

  test "map lines survive the watcher's normalization round-trip" do
    # Dolphin keys datagrams by the VERBATIM line; normalize must be
    # identity on well-formed map entries or lookups break.
    for {name, line} <- MemoryMap.menu_with_canary() do
      assert [{^name, ^line}] = MemoryWatcher.normalize_watches([{name, line}])
    end
  end

  test "canary is present in the standing set" do
    assert Keyword.has_key?(MemoryMap.menu_with_canary(), :rng_seed)
  end
end