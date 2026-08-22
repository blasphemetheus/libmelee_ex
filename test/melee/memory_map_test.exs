defmodule Melee.MemoryMapTest do
  use ExUnit.Case, async: true
  doctest Melee.MemoryMap

  alias Melee.{MemoryMap, MemoryWatcher}

  # ---------------------------------------------------------------
  # HtDP-style data definition for a MemoryMap watch line:
  #
  #   Line    = Address | Chain
  #   Address = HexU32 in MEM1-virtual [80000000, 817FFFFF]
  #   Chain   = Address (" " Offset)+   ; Read_U32-chase from Address
  #   Offset  = small hex (< 0x10000)   ; struct-field displacement
  #
  # Invariants the map must hold (each pinned below):
  #   * names unique across every exported set
  #   * every base address 0x80-prefixed (bare classic offsets = zero
  #     traffic on mainline — verified live 2026-08-22)
  #   * lines already normalized (dolphin keys datagrams verbatim)
  #   * the whole set round-trips through a simulated dolphin echo
  # ---------------------------------------------------------------

  describe "watch-line grammar invariants" do
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

    test "every base address is MEM1-virtual (0x80000000..0x817FFFFF)" do
      for {name, line} <- MemoryMap.menu_with_canary() do
        [base | offsets] = String.split(line)
        {addr, ""} = Integer.parse(base, 16)

        assert addr >= 0x8000_0000 and addr <= 0x817F_FFFF,
               "#{name}: base #{base} outside MEM1 virtual range"

        # Chain offsets are struct-field displacements, not addresses.
        for off <- offsets do
          {v, ""} = Integer.parse(off, 16)
          assert v < 0x10000, "#{name}: chain offset #{off} looks like an address"
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

    test "full dolphin-echo round trip: rendered set parses back to every name" do
      # Simulate dolphin's side end-to-end: Locations.txt lines echoed
      # verbatim as one composite datagram; every registered name must
      # be recoverable through parse + names lookup.
      watches = MemoryWatcher.normalize_watches(MemoryMap.menu_with_canary())
      names_by_line = Map.new(watches, fn {name, line} -> {line, name} end)

      frame =
        MemoryWatcher.render_locations(watches)
        |> String.split("\n", trim: true)
        |> Enum.map_join("", fn line -> "#{line}\n1\n" end)
        |> Kernel.<>(<<0>>)

      {:ok, updates} = MemoryWatcher.parse_datagram(frame)
      recovered = Enum.map(updates, fn {line, _v} -> Map.fetch!(names_by_line, line) end)
      assert Enum.sort(recovered) == watches |> Keyword.keys() |> Enum.sort()
    end
  end

  # ---------------------------------------------------------------
  # Data definition for the packed :menu_state word (0x80479D30):
  #
  #   SceneWord = <<major, pending_major, previous_major, minor>>
  #   stream_scene = (minor <<< 8) ||| major   ; the Slippi 0x3E word
  #
  # Classes: settled (major == pending == previous), transitioning
  # (pending != major), boundary bytes (0x00, 0xFF). Every scene the
  # stream parser knows is a free cross-check vector.
  # ---------------------------------------------------------------

  describe "decode_scene/1 — packed scene-controller word" do
    test "the live-observed word: offline VS CSS" do
      # 2026-08-22 live read at the offline VS CSS (mw_verify run).
      assert MemoryMap.decode_scene(0x02020200) == %{
               major: 0x02,
               pending_major: 0x02,
               previous_major: 0x02,
               minor: 0x00,
               stream_scene: 0x0002
             }
    end

    test "settled words map onto every scene the stream parser knows" do
      # {major, minor, expected scene_name} — mirrors Events.Menu's
      # taxonomy so a divergence in either module fails here.
      vectors = [
        {0x02, 0x00, :character_select},
        {0x02, 0x01, :stage_select},
        {0x02, 0x02, :in_game},
        {0x01, 0x00, :main_menu},
        {0x08, 0x00, :slippi_online_css},
        {0x00, 0x00, :press_start},
        {0x28, 0x00, :boot},
        {0x1E, 0x00, {:special_melee_css, :giant}},
        {0x1F, 0x01, {:special_melee_sss, :stamina}},
        {0x10, 0x02, {:special_melee_game, :super_sudden_death}}
      ]

      for {major, minor, expected} <- vectors do
        word = Bitwise.bor(major * 0x01010100, minor)
        assert MemoryMap.scene_name(word) == expected, "major=#{major} minor=#{minor}"

        assert MemoryMap.decode_scene(word).stream_scene ==
                 Bitwise.bor(Bitwise.bsl(minor, 8), major)
      end
    end

    test "transitioning word: pending differs from current major" do
      # CSS -> in-game transition committed but not landed: current
      # still VS/CSS, pending already VS... the interesting case is a
      # FAMILY change, e.g. main menu -> VS mode.
      decoded = MemoryMap.decode_scene(0x01020100)
      assert decoded.major == 0x01
      assert decoded.pending_major == 0x02
      assert decoded.previous_major == 0x01
      # stream_scene reflects the CURRENT scene only.
      assert decoded.stream_scene == 0x0001
    end

    test "byte boundaries: zero word and all-FF word decode totally" do
      assert MemoryMap.decode_scene(0x0000_0000).stream_scene == 0x0000
      assert MemoryMap.scene_name(0x0000_0000) == :press_start

      decoded = MemoryMap.decode_scene(0xFFFF_FFFF)
      assert decoded == %{
               major: 0xFF,
               pending_major: 0xFF,
               previous_major: 0xFF,
               minor: 0xFF,
               stream_scene: 0xFFFF
             }

      assert MemoryMap.scene_name(0xFFFF_FFFF) == {:unknown, 0xFFFF}
    end

    # SceneView classes: settled-known / settled-unknown / leaving.
    # Each class below is one clause a consumer's cond must handle.
    test "scene_view: settled at a known scene" do
      assert MemoryMap.scene_view(0x02020200) == {:settled, :character_select}
      assert MemoryMap.scene_view(0x08080800) == {:settled, :slippi_online_css}
      assert MemoryMap.scene_view(0x02020202) == {:settled, :in_game}
    end

    test "scene_view: settled at an unmapped scene stays identifiable" do
      assert MemoryMap.scene_view(0x42424200) == {:settled, {:unknown, 0x42}}
    end

    test "scene_view: leaving — pending family labeled at entry" do
      # Online CSS -> VS-family transition committed, not yet landed.
      assert MemoryMap.scene_view(0x08020800) ==
               {:leaving, :slippi_online_css, :character_select}

      # Pending an unmapped family: still a :leaving, target unknown.
      assert MemoryMap.scene_view(0x08420800) ==
               {:leaving, :slippi_online_css, {:unknown, 0x42}}
    end

    test "decode_scene rejects out-of-range input loudly" do
      assert_raise FunctionClauseError, fn -> MemoryMap.decode_scene(-1) end
      assert_raise FunctionClauseError, fn -> MemoryMap.decode_scene(0x1_0000_0000) end
    end
  end
end
