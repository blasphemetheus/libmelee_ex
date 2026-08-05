defmodule Melee.EventsTest do
  use ExUnit.Case, async: true

  alias Melee.Events
  alias Melee.GameState

  # --- binary construction helpers -----------------------------------------

  # Build an event binary of `size` bytes (command byte included), with
  # {offset, value-binary} fields patched in.
  defp event(command, size, fields) do
    base = <<command>> <> :binary.copy(<<0>>, size - 1)

    Enum.reduce(Map.to_list(Map.new(fields)), base, fn {off, value}, acc ->
      before_part = binary_part(acc, 0, off)
      after_start = off + byte_size(value)
      after_part = binary_part(acc, after_start, byte_size(acc) - after_start)
      before_part <> value <> after_part
    end)
  end

  defp u8(v), do: <<v>>
  defp u16(v), do: <<v::big-unsigned-16>>
  defp i32(v), do: <<v::big-signed-32>>
  defp f32(v), do: <<v::big-float-32>>

  # PAYLOADS event declaring sizes (command byte NOT included in wire size).
  defp payloads(sizes) do
    table = for {cmd, size} <- sizes, into: <<>>, do: <<cmd, size - 1::big-unsigned-16>>
    <<0x35, byte_size(table) + 1>> <> table
  end

  @sizes %{
    0x36 => 0x2ED,
    0x37 => 0x41,
    0x38 => 0x85,
    0x39 => 0x2,
    0x3A => 0x9,
    0x3B => 0x2C,
    0x3C => 0x9
  }

  defp game_start(fields \\ []) do
    defaults = [
      # SLP version 3.16.0
      {0x1, u8(3)},
      {0x2, u8(16)},
      {0x3, u8(0)},
      # external stage id: Final Destination
      {0x13, u16(0x20)},
      # player types: p1/p2 humans (0), p3/p4 empty (3)
      {0x66, u8(0)},
      {0x66 + 0x24, u8(0)},
      {0x66 + 0x24 * 2, u8(3)},
      {0x66 + 0x24 * 3, u8(3)},
      # costumes
      {0x68, u8(1)},
      {0x68 + 0x24, u8(2)}
    ]

    event(0x36, @sizes[0x36], Map.merge(Map.new(defaults), Map.new(fields)))
  end

  defp pre_frame(frame, port, fields \\ []) do
    defaults = [
      {0x1, i32(frame)},
      {0x5, u8(port - 1)},
      # sticks at raw 0.0 => processed 0.5
      {0x19, f32(0.0)},
      {0x1D, f32(0.0)}
    ]

    event(0x37, @sizes[0x37], Map.merge(Map.new(defaults), Map.new(fields)))
  end

  defp post_frame(frame, port, fields \\ []) do
    defaults = [
      {0x1, i32(frame)},
      {0x5, u8(port - 1)},
      # character byte (internal id)
      {0x7, u8(0x2)},
      # action: STANDING (14)
      {0x8, u16(14)},
      {0xA, f32(10.0)},
      {0xE, f32(0.0)},
      # facing right
      {0x12, f32(1.0)},
      {0x16, f32(42.5)},
      {0x1A, f32(60.0)},
      {0x21, u8(4)},
      {0x22, f32(7.0)},
      {0x32, u8(2)}
    ]

    event(0x38, @sizes[0x38], Map.merge(Map.new(defaults), Map.new(fields)))
  end

  defp bookend(frame) do
    event(0x3C, @sizes[0x3C], [{0x1, i32(frame)}])
  end

  defp full_frame(parser, frame, opts \\ []) do
    p1_post = Keyword.get(opts, :p1_post, [])

    stream =
      pre_frame(frame, 1) <>
        pre_frame(frame, 2) <>
        post_frame(frame, 1, p1_post) <>
        post_frame(frame, 2, [{0xA, f32(-20.0)}, {0xE, f32(0.0)}]) <>
        bookend(frame)

    Events.handle_game_event(parser, stream)
  end

  defp connected_parser do
    parser = Events.new()
    {:continue, parser} = Events.handle_game_event(parser, payloads(@sizes))
    {:continue, parser} = Events.handle_game_event(parser, game_start())
    parser
  end

  # --- tests ----------------------------------------------------------------

  describe "payload size table" do
    test "parses sizes and continues" do
      assert {:continue, parser} = Events.handle_game_event(Events.new(), payloads(@sizes))
      assert parser.payload_sizes[0x38] == 0x85
      assert parser.payload_sizes[0x36] == 0x2ED
    end

    test "unknown event without a size table entry errors" do
      assert {:error, {:unknown_event, 0x38}, _} =
               Events.handle_game_event(Events.new(), <<0x38, 1, 2, 3>>)
    end
  end

  describe "game start" do
    test "records version, stage, costumes" do
      parser = connected_parser()
      assert parser.slp_version == {3, 16, 0}
      # FINAL_DESTINATION internal id
      assert parser.current_stage == 0x19
      assert elem(parser.costumes, 0) == 1
      assert elem(parser.costumes, 1) == 2
      refute parser.is_teams
    end
  end

  describe "frame assembly" do
    test "pre+post+bookend completes a frame" do
      parser = connected_parser()
      assert {:frame_complete, %GameState{} = gs, parser} = full_frame(parser, 123)

      assert gs.frame == 123
      assert gs.stage == 0x19
      assert map_size(gs.players) == 2

      p1 = gs.players[1]
      assert p1.character == 0x2
      assert p1.action == 14
      assert p1.position.x == 10.0
      assert_in_delta p1.percent, 42.5, 1.0e-4
      assert p1.stock == 4
      assert p1.jumps_left == 2
      assert p1.costume == 1
      assert p1.facing == true

      # distance: p1 at (10,0), p2 at (-20,0)
      assert_in_delta gs.distance, 30.0, 1.0e-4

      assert parser.frame == 123
    end

    test "controller state decodes sticks and buttons" do
      parser = connected_parser()

      pre =
        pre_frame(5, 1, [
          # main stick raw 1.0 => 1.0 processed... (v/2)+0.5
          {0x19, f32(1.0)},
          {0x1D, f32(-1.0)},
          # physical buttons: A (0x0100) + Z (0x0010)
          {0x31, u16(0x0110)}
        ])

      stream = pre <> post_frame(5, 1) <> bookend(5)
      assert {:frame_complete, gs, _} = Events.handle_game_event(parser, stream)

      cs = gs.players[1].controller_state
      assert cs.main_stick == {1.0, 0.0}
      assert cs.button.a
      assert cs.button.z
      refute cs.button.b
    end

    test "rollback frames are skipped (with a :rollback signal) when skip_rollback_frames" do
      parser = connected_parser()
      assert {:frame_complete, _, parser} = full_frame(parser, 100)
      # Same frame again (rollback re-simulation): skipped, tagged so the
      # console can flush controllers in blocking-input mode.
      assert {:rollback, parser} = full_frame(parser, 100)
      # Next frame comes through.
      assert {:frame_complete, gs, _} = full_frame(parser, 101)
      assert gs.frame == 101
    end

    test "game start sets the game_started flag until cleared" do
      parser = Events.new()
      {:continue, parser} = Events.handle_game_event(parser, payloads(@sizes))
      refute parser.game_started
      {:continue, parser} = Events.handle_game_event(parser, game_start())
      assert parser.game_started

      parser = Events.clear_game_started(parser)
      refute parser.game_started
    end

    test "rollback frames are kept when skip_rollback_frames: false" do
      parser = %{connected_parser() | skip_rollback_frames: false}
      assert {:frame_complete, _, parser} = full_frame(parser, 100)
      assert {:frame_complete, gs, _} = full_frame(parser, 100)
      assert gs.frame == 100
    end

    test "game end halts the stream" do
      parser = connected_parser()
      game_end = event(0x39, @sizes[0x39], [])
      assert {:game_end, _} = Events.handle_game_event(parser, game_end)
    end

    test "split delivery: events can arrive across packets" do
      parser = connected_parser()
      assert {:continue, parser} = Events.handle_game_event(parser, pre_frame(7, 1))
      assert {:continue, parser} = Events.handle_game_event(parser, post_frame(7, 1))
      assert {:frame_complete, gs, _} = Events.handle_game_event(parser, bookend(7))
      assert gs.frame == 7
    end
  end

  describe "item update" do
    test "adds projectiles to the frame" do
      parser = connected_parser()

      item =
        event(0x3B, @sizes[0x3B], [
          {0x1, i32(9)},
          # type
          {0x5, u16(0x30)},
          {0x7, u8(1)},
          {0x14, f32(5.0)},
          {0x18, f32(6.0)},
          # owner (3.6.0+): port index 1 => port 2
          {0x2A, u8(1)}
        ])

      stream = pre_frame(9, 1) <> post_frame(9, 1) <> item <> bookend(9)
      assert {:frame_complete, gs, _} = Events.handle_game_event(parser, stream)

      assert [proj] = gs.projectiles
      assert proj.type == 0x30
      assert proj.position.x == 5.0
      assert proj.owner == 2
    end
  end

  describe "nana" do
    test "nana events populate the player's nana state" do
      parser = connected_parser()

      stream =
        pre_frame(3, 1) <>
          pre_frame(3, 1, [{0x6, u8(1)}]) <>
          post_frame(3, 1) <>
          post_frame(3, 1, [{0x6, u8(1)}, {0xA, f32(99.0)}]) <>
          bookend(3)

      assert {:frame_complete, gs, _} = Events.handle_game_event(parser, stream)
      p1 = gs.players[1]
      assert p1.nana
      assert p1.nana.position.x == 99.0
      assert p1.position.x == 10.0
    end
  end

  describe "property: parser never crashes" do
    use ExUnitProperties

    property "garbage after a valid size table returns a tagged result" do
      parser = connected_parser()

      check all bin <- StreamData.binary(max_length: 200) do
        result = Events.handle_game_event(parser, bin)

        assert elem(result, 0) in [:frame_complete, :continue, :rollback, :game_end, :error]
      end
    end
  end
end
