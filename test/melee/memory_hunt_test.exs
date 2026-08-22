defmodule Melee.MemoryHuntTest do
  use ExUnit.Case, async: true

  alias Melee.{MemoryHunt, MemoryWatcher}

  describe "candidates/3 — region to watch lines" do
    test "covers the region at the stride, unique hunt-prefixed names" do
      c = MemoryHunt.candidates(0x8043_0000, 3, 8)

      assert c == [
               h_80430000: "80430000",
               h_80430008: "80430008",
               h_80430010: "80430010"
             ]

      names = Keyword.keys(c)
      assert length(names) == length(Enum.uniq(names))
    end

    test "default stride is one u32" do
      assert MemoryHunt.candidates(0x8043_0000, 2) ==
               [h_80430000: "80430000", h_80430004: "80430004"]
    end

    test "lines are valid MemoryWatcher lines (normalization identity)" do
      for {name, line} <- MemoryHunt.candidates(0x8111_6B00, 50) do
        assert [{^name, ^line}] = MemoryWatcher.normalize_watches([{name, line}])
      end
    end

    test "boundary: a region ending exactly at the MEM1 top is allowed" do
      # last slot 0x817FFFFC..0x817FFFFF — the final u32 of MEM1.
      assert [_ | _] = MemoryHunt.candidates(0x817F_FFF0, 4, 4)
    end

    test "out-of-range and misaligned regions raise (silent 0-reads poison the differential)" do
      assert_raise ArgumentError, fn -> MemoryHunt.candidates(0x817F_FFF8, 4, 4) end
      assert_raise ArgumentError, fn -> MemoryHunt.candidates(0x7FFF_FFF0, 4, 4) end
      assert_raise FunctionClauseError, fn -> MemoryHunt.candidates(0x8043_0002, 4, 4) end
      assert_raise FunctionClauseError, fn -> MemoryHunt.candidates(0x8043_0000, 4, 2) end
    end
  end

  describe "changed/2 — snapshot diff" do
    test "empty snapshots: nothing changed" do
      assert MemoryHunt.changed(%{}, %{}) == []
    end

    test "appearance IS change (on-change semantics: first datagram = changed since boot)" do
      assert MemoryHunt.changed(%{}, %{a: 5}) == [{:a, nil, 5}]
    end

    test "value change reported with both values; unchanged excluded" do
      assert MemoryHunt.changed(%{a: 1, b: 2}, %{a: 9, b: 2}) == [{:a, 1, 9}]
    end

    test "result is key-sorted for stable reports" do
      assert MemoryHunt.changed(%{}, %{z: 1, a: 2}) == [{:a, nil, 2}, {:z, nil, 1}]
    end
  end

  describe "correlated/2 — the differential verdict" do
    test "driven minus idle, accepting Change triples or bare keys" do
      driven = [{:cursor, nil, 7}, {:frame_ctr, 1, 2}, {:rng, 3, 4}]
      idle = [:frame_ctr, :rng]
      assert MemoryHunt.correlated(driven, idle) == [:cursor]
    end

    test "always-ticking counters die here even if they also moved driven" do
      assert MemoryHunt.correlated([:rng, :cursor], [{:rng, 1, 2}]) == [:cursor]
    end

    test "no survivors is a valid verdict" do
      assert MemoryHunt.correlated([:rng], [:rng]) == []
    end
  end

  describe "f32_class/1 — stale-read triage" do
    test "the four classes" do
      assert MemoryHunt.f32_class(0x0000_0000) == :zero
      assert MemoryHunt.f32_class(0x8000_0000) == :zero
      # the live stale-CSS read (~4.77e-39)
      assert MemoryHunt.f32_class(0x0034_0000) == :denormal
      # a live cursor x (-23.04)
      assert MemoryHunt.f32_class(0xC1B8_58C6) == :normal
      assert MemoryHunt.f32_class(0x7FC0_0000) == :nan_or_inf
      assert MemoryHunt.f32_class(0x7F80_0000) == :nan_or_inf
      assert MemoryHunt.f32_class(0xFF80_0000) == :nan_or_inf
    end
  end

  describe "tracks?/2 — commanded-coordinate confirmation" do
    test "all observations within tolerance pass" do
      assert MemoryHunt.tracks?([{-22.3, -22.0}, {10.4, 10.0}])
    end

    test "one out-of-tolerance observation fails the candidate" do
      refute MemoryHunt.tracks?([{-22.3, -22.0}, {40.0, 10.0}])
    end

    test "junk observations fail (a real address never decodes to junk under command)" do
      refute MemoryHunt.tracks?([{:nan, -22.0}])
      refute MemoryHunt.tracks?([{nil, -22.0}])
    end

    test "no evidence is not a pass" do
      refute MemoryHunt.tracks?([])
    end

    test "tolerance is a parameter" do
      assert MemoryHunt.tracks?([{15.0, 10.0}], 5.0)
      refute MemoryHunt.tracks?([{15.0, 10.0}], 4.0)
    end
  end
end
