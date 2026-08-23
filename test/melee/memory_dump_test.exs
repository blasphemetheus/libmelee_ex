defmodule Melee.MemoryDumpTest do
  use ExUnit.Case, async: true

  alias Melee.MemoryDump

  # ---------------------------------------------------------------
  # parse_maps/1: /proc maps grammar. Classes: rw big enough / rw too
  # small / big but read-only / anonymous vs pathed / malformed lines.
  # ---------------------------------------------------------------
  describe "parse_maps/1" do
    test "keeps only rw mappings of at least MEM1 size, with paths" do
      content = """
      7f0000000000-7f0001800000 rw-s 00000000 00:01 42 /dev/shm/dolphin-emu.123 (deleted)
      7f0002000000-7f0002001000 rw-p 00000000 00:00 0
      7f0003000000-7f0005000000 r--p 00000000 00:00 0
      7f0006000000-7f0008000000 rw-p 00000000 00:00 0
      malformed line
      """

      assert MemoryDump.parse_maps(content) == [
               {0x7F0000000000, "/dev/shm/dolphin-emu.123 (deleted)"},
               {0x7F0006000000, ""}
             ]
    end

    test "empty content: no mappings" do
      assert MemoryDump.parse_maps("") == []
    end
  end

  # ---------------------------------------------------------------
  # diff/2: equal / one word / first word / last word / many.
  # ---------------------------------------------------------------
  describe "diff/2" do
    test "identical dumps: empty diff" do
      d = :crypto.strong_rand_bytes(64)
      assert MemoryDump.diff(d, d) == []
    end

    test "single changed word reports offset and both values" do
      before = <<0::32, 1::32, 2::32>>
      after_ = <<0::32, 9::32, 2::32>>
      assert MemoryDump.diff(before, after_) == [{4, 1, 9}]
    end

    test "boundary words: first and last" do
      before = <<1::32, 0::32, 0::32, 4::32>>
      after_ = <<7::32, 0::32, 0::32, 8::32>>
      assert MemoryDump.diff(before, after_) == [{0, 1, 7}, {12, 4, 8}]
    end

    test "offsets are byte offsets, u32-aligned, ascending" do
      before = :binary.copy(<<0::32>>, 16)
      after_ = :binary.copy(<<0::32>>, 8) <> <<5::32>> <> :binary.copy(<<0::32>>, 7)
      assert MemoryDump.diff(before, after_) == [{32, 0, 5}]
    end
  end

  test "virtual/1 maps MEM1 offsets to 0x80000000-based addresses" do
    assert MemoryDump.virtual(0x479D30) == 0x80479D30
  end
end
