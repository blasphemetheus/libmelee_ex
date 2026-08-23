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
      # 8 globals + 5 fields x 4 ports
      assert length(watches) == 28

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

    test "mainline cursor block: classic layout shifted +0x17200, stride 0xB80 intact" do
      # The 2026-08-22 park-and-scan finding: the whole 4-port cursor
      # block relocated together; P1 verified bit-exact live. This pins
      # the structural facts so a future edit can't silently break the
      # derivation chain for the unverified ports.
      addrs =
        for p <- 1..4 do
          MemoryMap.menu()
          |> Keyword.fetch!(:"css_p#{p}_cursor_x")
          |> String.to_integer(16)
        end

      assert Enum.zip(addrs, tl(addrs)) |> Enum.map(fn {a, b} -> a - b end) ==
               [0xB80, 0xB80, 0xB80]

      assert hd(addrs) == 0x81118DEC + 0x17200
    end

    test "selected-character array: base 0x8043208C, stride 8 (2026-08-22c toggle experiment)" do
      # P1 verified with fox (0x21 -> 0x02), P2 with falco (0x21 ->
      # 0x14), flips back on B-deselect; P3/P4 stride-derived. Pins the
      # structure so an edit can't silently break the derivation chain.
      addrs =
        for p <- 1..4 do
          MemoryMap.menu()
          |> Keyword.fetch!(:"css_p#{p}_selected")
          |> String.to_integer(16)
        end

      assert Enum.zip(addrs, tl(addrs)) |> Enum.map(fn {a, b} -> b - a end) == [8, 8, 8]
      assert hd(addrs) == 0x8043208C
    end

    test "css_selected/1 decode: :none sentinel, every other byte an external id" do
      assert MemoryMap.css_selected(0x21) == :none
      assert MemoryMap.css_selected(0x02) == {:character, 0x02}
      assert MemoryMap.css_selected(0x14) == {:character, 0x14}

      for id <- 0..0xFF, id != 0x21 do
        assert MemoryMap.css_selected(id) == {:character, id}
      end
    end

    test "canary is present in the standing set" do
      assert Keyword.has_key?(MemoryMap.menu_with_canary(), :rng_seed)
    end

    test "game set: unique names, well-formed lines, MEM1-virtual bases, expected count" do
      watches = MemoryMap.game()
      names = Keyword.keys(watches)
      assert length(names) == length(Enum.uniq(names))
      # game_frame + rng_seed + 7 fields x 4 ports
      assert length(watches) == 30

      for {name, line} <- watches do
        [base | offsets] = String.split(line)
        assert {addr, ""} = Integer.parse(base, 16), "bad base in #{name}"
        assert addr >= 0x8000_0000 and addr <= 0x817F_FFFF, "#{name} outside MEM1"

        for off <- offsets do
          {v, ""} = Integer.parse(off, 16)
          assert v < 0x10000
        end

        assert [{^name, ^line}] = MemoryWatcher.normalize_watches([{name, line}])
      end
    end

    test "fod set: the two verified platform-height f32 addresses" do
      # 2026-08-24 hunt+verify (tmp/mw_fod_height_hunt, tmp/mw_fod_verify):
      # RAM f32 == stream fod_platforms value exactly (max_dev 0.0 over
      # 251 samples, range -1.0..32.3), each address replicated across
      # two boots. Pin the addresses.
      watches = MemoryMap.fod()
      assert watches[:fod_platform_left] == "80C62F90"
      assert watches[:fod_platform_right] == "80C63CF0"

      for {name, line} <- watches do
        assert [{^name, ^line}] = MemoryWatcher.normalize_watches([{name, line}])
      end
    end

    test "ps set: transformation digit address + decode" do
      # 2026-08-24 hunt+verify: file-loader name buffer digit position;
      # flips step-exact with the stream transformation event (two
      # boots, all five values, live-witnessed water/rock/fire/water).
      assert MemoryMap.ps()[:ps_transform_digit] == "8043205C"
      assert MemoryMap.ps_transform(?.) == :normal
      assert MemoryMap.ps_transform(?1) == :fire
      assert MemoryMap.ps_transform(?2) == :grass
      assert MemoryMap.ps_transform(?3) == :water
      assert MemoryMap.ps_transform(?4) == :rock
      assert MemoryMap.ps_transform(?M) == :unknown
    end

    test "game set: classic player block layout (base 0x80453080, stride 0xE90)" do
      # Quartet run 2026-08-22c verified p1/p2 live (x/y/action
      # bit-exact vs the stream); p3/p4 stride-derived from the same
      # classic CSV. Pin the structure.
      xs =
        for p <- 1..4 do
          MemoryMap.game() |> Keyword.fetch!(:"p#{p}_x") |> String.to_integer(16)
        end

      assert hd(xs) == 0x80453090
      assert Enum.zip(xs, tl(xs)) |> Enum.map(fn {a, b} -> b - a end) == [0xE90, 0xE90, 0xE90]

      # Action rides the entity pointer at base+0xB0.
      assert MemoryMap.game()[:p1_action] == "80453130 70"
      assert MemoryMap.game()[:p2_action] == "80453FC0 70"
    end

    test "merge_css/2: empty snapshot is the identity" do
      gs = css_gamestate()
      assert MemoryMap.merge_css(gs, %{}) == gs
    end

    test "merge_css/2: cursor substituted only when BOTH axes decode finite" do
      gs = css_gamestate()

      merged = MemoryMap.merge_css(gs, %{css_p1_cursor_x: f32(-22.0), css_p1_cursor_y: f32(11.5)})
      assert merged.players[1].cursor == %Melee.Position{x: -22.0, y: 11.5}

      # x alone, or a NaN axis, keeps the stream cursor.
      assert MemoryMap.merge_css(gs, %{css_p1_cursor_x: f32(-22.0)}) == gs
      assert MemoryMap.merge_css(gs, %{css_p1_cursor_x: f32(-22.0), css_p1_cursor_y: 0x7FC00000}) == gs
    end

    test "merge_css/2: hover byte sets character via the CSS-grid scheme" do
      gs = css_gamestate()

      # fox: CSS-grid 0x0A (top byte of the u32 at 803F0E0A) -> internal 0x01
      merged = MemoryMap.merge_css(gs, %{css_p1_character: 0x0A000000})
      assert merged.players[1].character == 0x01

      # unknown hover id: keep the stream value
      assert MemoryMap.merge_css(gs, %{css_p1_character: 0x63000000}) == gs
    end

    test "merge_css/2: selected word drives coin_down + locked character (game-external scheme)" do
      gs = css_gamestate()

      # 0x21 = none: coin in hand
      merged = MemoryMap.merge_css(gs, %{css_p1_selected: 0x21})
      assert merged.players[1].coin_down == false

      # fox game-external 0x02 -> coin placed, character locked (internal 0x01),
      # overriding the hover byte
      merged = MemoryMap.merge_css(gs, %{css_p1_character: 0x09000000, css_p1_selected: 0x02})
      assert merged.players[1].coin_down == true
      assert merged.players[1].character == 0x01
      assert merged.players[1].character_selected == 0x01

      # implausible word: untouched
      assert MemoryMap.merge_css(gs, %{css_p1_selected: 0x12345678}) == gs
    end

    test "merge_css/3 fields: :static skips the heap-block cursor, keeps static fields" do
      gs = css_gamestate()

      snapshot = %{
        css_p1_cursor_x: f32(-22.0),
        css_p1_cursor_y: f32(11.5),
        css_p1_selected: 0x02
      }

      merged = MemoryMap.merge_css(gs, snapshot, fields: :static)
      # cursor untouched (heap address unproven at this scene)...
      assert merged.players[1].cursor == gs.players[1].cursor
      # ...but the static-region selection still overlays.
      assert merged.players[1].coin_down == true
      assert merged.players[1].character_selected == 0x01
    end

    test "merge_css/2: status byte, ready banner, and port independence" do
      gs = css_gamestate()

      merged =
        MemoryMap.merge_css(gs, %{
          css_p2_status: 0x01000000,
          css_p2_selected: 0x14,
          ready_to_start: 0x00000000
        })

      assert merged.players[2].controller_status == 1
      assert merged.players[2].coin_down == true
      assert merged.players[2].character_selected == 0x16
      # p1 untouched by p2 observations
      assert merged.players[1] == gs.players[1]
      assert merged.ready_to_start == true

      not_ready = MemoryMap.merge_css(gs, %{ready_to_start: 0x01000000})
      assert not_ready.ready_to_start == false
    end

    test "direct_code/0 watch set + decode_direct_code/1 on live-observed bytes" do
      watches = MemoryMap.direct_code()
      assert length(watches) == 6
      assert watches[:code_buf_0] == "804A0740"

      # The exact bytes read live 2026-08-23 with "EXPH#288" autofilled
      # (3 bytes/char: SJIS pair + NUL), first 16 bytes = 4 words.
      # (16 of 24 bytes -> the 6th char is a partial chunk, discarded)
      words = [0x82640082, 0x7700826F, 0x00826700, 0x81940082]
      assert MemoryMap.decode_direct_code(words) == "EXPH#"

      # After the replacing keystroke: "A" + NUL terminator.
      assert MemoryMap.decode_direct_code([0x82600000, 0x0, 0x0, 0x0, 0x0, 0x0]) == "A"
      # Empty field.
      assert MemoryMap.decode_direct_code([0, 0, 0, 0, 0, 0]) == ""
      # Unknown-value words halt the decode instead of raising.
      assert MemoryMap.decode_direct_code([:unknown]) == ""
    end

    test "percent/1 and stock/1 decode the verified raw encodings" do
      # Live samples from the quartet run: 3% read 0x30000, 4 stocks
      # read 0x04000000.
      assert MemoryMap.percent(0x30000) == 3
      assert MemoryMap.percent(0) == 0
      assert MemoryMap.stock(0x04000000) == 4
      assert MemoryMap.stock(0) == 0
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

    test "scene_view: the online in-game word (bot14 capture, replay-correlated)" do
      # Word held through both live games; flips ~2-3s before the
      # replay's first frame and back ~2s after game end. RAM-only:
      # the stream reports menu_state 6 for the whole online flow.
      assert MemoryMap.scene_view(0x08080104) == {:settled, :slippi_online_game}
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

  # ---------------------------------------------------------------
  # merge_css/2 fixtures
  # ---------------------------------------------------------------

  defp css_gamestate do
    %Melee.GameState{
      menu_state: Melee.Enums.Menu.to_id(:character_select),
      ready_to_start: false,
      players: %{
        1 => %Melee.PlayerState{cursor: %Melee.Position{x: 0.0, y: 0.0}},
        2 => %Melee.PlayerState{cursor: %Melee.Position{x: 5.0, y: 5.0}}
      }
    }
  end

  defp f32(x) do
    <<u::32>> = <<x::float-big-32>>
    u
  end
end
