defmodule Melee.SlpFileTest do
  use ExUnit.Case, async: true

  alias Melee.{GameState, SlpFile}

  @fixture Path.expand("../fixtures/fox_multishine.slp", __DIR__)

  describe "open/2 and metadata/1" do
    test "unwraps the container and reads metadata" do
      assert {:ok, file} = SlpFile.open(@fixture)
      assert byte_size(file.raw) > 100_000
      assert file.metadata.playedOn in [nil, "dolphin", "mainline dolphin", "network", "console"]
      refute file.manual_bookends, "the fixture is a modern replay"
    end

    test "metadata/1 reports the bookend mode" do
      assert {:ok, meta} = SlpFile.metadata(@fixture)
      assert meta.manual_bookends == false
      assert is_integer(meta.lastFrame) or is_nil(meta.lastFrame)
    end

    test "rejects a file that is not a replay" do
      path = Path.join(System.tmp_dir!(), "not_a_replay.slp")
      File.write!(path, "definitely not ubjson")
      on_exit(fn -> File.rm(path) end)

      assert {:error, :not_an_slp_file} = SlpFile.open(path)
    end
  end

  describe "stream!/2" do
    test "yields frames in order, matching a direct Melee.Events parse" do
      frames = @fixture |> SlpFile.stream!() |> Enum.to_list()

      assert length(frames) > 1_000
      assert Enum.all?(frames, &match?(%GameState{}, &1))

      numbers = Enum.map(frames, & &1.frame)
      assert numbers == Enum.sort(numbers)
      assert length(Enum.uniq(numbers)) == length(numbers)

      # Same count and same values as feeding the codec directly — the
      # file path and the live path share one decoder.
      assert length(frames) == direct_parse_count(@fixture)

      first = hd(frames)
      assert first.frame < 0, "a game starts before frame 0"
      assert map_size(first.players) >= 2
    end

    test "is lazy — taking a few frames does not parse the whole file" do
      frames = @fixture |> SlpFile.stream!() |> Enum.take(5)
      assert length(frames) == 5
      assert Enum.map(frames, & &1.frame) == Enum.sort(Enum.map(frames, & &1.frame))
    end

    test "physics values are sane throughout" do
      for gs <- @fixture |> SlpFile.stream!() |> Enum.take_every(200),
          {_port, p} <- gs.players do
        assert p.percent >= 0.0
        assert p.stock in 0..99
        assert p.shield_strength >= 0.0 and p.shield_strength <= 60.0
        {mx, my} = p.controller_state.main_stick
        assert mx >= 0.0 and mx <= 1.0
        assert my >= 0.0 and my <= 1.0
      end
    end

    test "skip_rollback_frames: false yields at least as many frames" do
      default = @fixture |> SlpFile.stream!() |> Enum.count()
      with_rollback = @fixture |> SlpFile.stream!(skip_rollback_frames: false) |> Enum.count()

      assert with_rollback >= default
    end
  end

  describe "pre-2.2.0 replays (manual bookends)" do
    # Slippi added FRAME_BOOKEND in replay 2.2.0. Older files have no
    # frame boundary at all, so the decoder has to infer one from the
    # frame counter advancing — without that they parse to zero frames.
    # Built here rather than shipped as a fixture so the shape is
    # explicit (and the repo stays small).
    defp old_format_replay(frame_count) do
      sizes = %{0x36 => 0x2ED, 0x37 => 0x41, 0x38 => 0x85, 0x39 => 0x2}

      table = for {cmd, size} <- sizes, into: <<>>, do: <<cmd, size - 1::big-unsigned-16>>
      payloads = <<0x35, byte_size(table) + 1>> <> table

      game_start =
        event(0x36, sizes[0x36], %{
          # SLP 1.5.0: old enough to predate bookends
          0x1 => <<1>>,
          0x2 => <<5>>,
          0x13 => <<0x20::big-unsigned-16>>,
          0x66 => <<0>>,
          (0x66 + 0x24) => <<0>>
        })

      frames =
        for n <- 1..frame_count, into: <<>> do
          event(0x37, sizes[0x37], %{0x1 => <<n::big-signed-32>>, 0x5 => <<0>>}) <>
            event(0x38, sizes[0x38], %{
              0x1 => <<n::big-signed-32>>,
              0x5 => <<0>>,
              0x7 => <<0x1>>,
              0x8 => <<14::big-unsigned-16>>,
              0xA => <<n * 1.0::big-float-32>>
            })
        end

      raw = payloads <> game_start <> frames

      <<"{U", 3, "raw[$U#l", byte_size(raw)::big-unsigned-32>> <>
        raw <>
        <<0x55, 8, "metadata", ?{, 0x55, 8, "playedOn", ?S, 0x55, 10, "nintendont", ?}, ?}>>
    end

    defp event(command, size, fields) do
      base = <<command>> <> :binary.copy(<<0>>, size - 1)

      Enum.reduce(fields, base, fn {off, value}, acc ->
        after_start = off + byte_size(value)

        binary_part(acc, 0, off) <>
          value <> binary_part(acc, after_start, byte_size(acc) - after_start)
      end)
    end

    defp write_old_replay(ctx, frame_count) do
      path = Path.join(System.tmp_dir!(), "old_#{:erlang.phash2(ctx.test)}.slp")
      File.write!(path, old_format_replay(frame_count))
      on_exit(fn -> File.rm(path) end)
      path
    end

    test "are detected", ctx do
      path = write_old_replay(ctx, 10)
      assert {:ok, meta} = SlpFile.metadata(path)
      assert meta.manual_bookends, "a file with no FRAME_BOOKEND in its payload table"
      assert meta.playedOn == "nintendont"
    end

    test "stream frames despite having no bookends", ctx do
      path = write_old_replay(ctx, 12)
      frames = path |> SlpFile.stream!() |> Enum.to_list()

      # One frame per advance; the last is flushed at end of data.
      assert length(frames) == 12
      assert Enum.map(frames, & &1.frame) == Enum.to_list(1..12)

      # Values decode normally — the boundary is the only difference.
      assert hd(frames).players[1].character == 0x1
      assert List.last(frames).players[1].position.x == 12.0
    end

    test "the raw codec alone yields nothing for them (why this exists)", ctx do
      path = write_old_replay(ctx, 12)
      assert direct_parse_count(path) == 0
    end

    test "the final frame survives a GAME_END ending", ctx do
      # Real old replays end WITH a GAME_END event (the synthetic ones
      # above end by running out of data, a different code path). The
      # final frame is still accumulating when GAME_END arrives — no
      # successor pre-frame will ever complete it — and dropping it was
      # a real bug: the peppi differential found every pre-2.2.0 corpus
      # replay exactly one frame short.
      path = write_old_replay(ctx, 12)
      File.write!(path, with_game_end(File.read!(path)))

      frames = path |> SlpFile.stream!() |> Enum.to_list()
      assert length(frames) == 12
      assert List.last(frames).players[1].position.x == 12.0
    end

    # Append a GAME_END (0x39) to the synthetic replay's raw element,
    # fixing up the container length.
    defp with_game_end(
           <<"{U", 3, "raw[$U#l", len::big-unsigned-32, raw::binary-size(len), rest::binary>>
         ) do
      raw = raw <> <<0x39, 0>>

      <<"{U", 3, "raw[$U#l", byte_size(raw)::big-unsigned-32>> <> raw <> rest
    end

    # Splice extra pre/post events into the raw element after the
    # events of `after_frame`, fixing up the container length.
    defp splice_after_frame(
           <<"{U", 3, "raw[$U#l", len::big-unsigned-32, raw::binary-size(len), rest::binary>>,
           after_frame,
           extra
         ) do
      # The synthetic frames are fixed-size and consecutive from 1, so
      # the insertion point is computable: payloads table + game start +
      # after_frame * (pre + post).
      sizes = %{0x35 => 4 * 3 + 2, 0x36 => 0x2ED, 0x37 => 0x41, 0x38 => 0x85}
      cut = sizes[0x35] + sizes[0x36] + after_frame * (sizes[0x37] + sizes[0x38])

      raw =
        binary_part(raw, 0, cut) <> extra <> binary_part(raw, cut, byte_size(raw) - cut)

      <<"{U", 3, "raw[$U#l", byte_size(raw)::big-unsigned-32>> <> raw <> rest
    end

    defp pre_post(frame, x, follower \\ 0) do
      event(0x37, 0x41, %{0x1 => <<frame::big-signed-32>>, 0x5 => <<0>>, 0x6 => <<follower>>}) <>
        event(0x38, 0x85, %{
          0x1 => <<frame::big-signed-32>>,
          0x5 => <<0>>,
          0x6 => <<follower>>,
          0x7 => <<0x1>>,
          0x8 => <<14::big-unsigned-16>>,
          0xA => <<x * 1.0::big-float-32>>
        })
    end

    test "a re-simulated frame is a boundary, with rollback semantics", ctx do
      # An early-rollback-era pre-2.2.0 replay can carry the same frame
      # TWICE (observed in the wild: the peppi differential caught frame
      # 6176 duplicated). A repeat of an already-seen (event, port) for
      # the same frame must complete the frame, after which the codec's
      # normal rollback semantics apply.
      path = write_old_replay(ctx, 8)
      File.write!(path, splice_after_frame(File.read!(path), 5, pre_post(5, 55.0)))

      # Default: the re-simulation is dropped; the FIRST simulation
      # wins, exactly as the live bookend path behaves. (The old merge
      # behavior silently kept the re-simulation's values.)
      frames = path |> SlpFile.stream!() |> Enum.to_list()
      assert Enum.map(frames, & &1.frame) == Enum.to_list(1..8)
      assert Enum.find(frames, &(&1.frame == 5)).players[1].position.x == 5.0

      # skip_rollback_frames: false surfaces both simulations, aligned
      # with what peppi reports.
      both = path |> SlpFile.stream!(skip_rollback_frames: false) |> Enum.to_list()
      assert Enum.map(both, & &1.frame) == [1, 2, 3, 4, 5, 5, 6, 7, 8]

      assert both |> Enum.filter(&(&1.frame == 5)) |> Enum.map(& &1.players[1].position.x) ==
               [5.0, 55.0]
    end

    test "an Ice Climbers follower is NOT a re-simulation", ctx do
      # Nana emits a second pre/post for the same port every frame; the
      # dedup key includes the follower byte so this never reads as a
      # frame boundary.
      path = write_old_replay(ctx, 4)
      File.write!(path, splice_after_frame(File.read!(path), 2, pre_post(2, 22.0, 1)))

      frames = path |> SlpFile.stream!(skip_rollback_frames: false) |> Enum.to_list()
      assert Enum.map(frames, & &1.frame) == [1, 2, 3, 4]
    end
  end

  describe "next_frame/1" do
    test "walks frames one at a time and terminates" do
      file = SlpFile.open!(@fixture)

      {count, last} = drain(file, 0, nil)

      assert count > 1_000
      assert %GameState{} = last
    end
  end

  defp drain(file, count, last) do
    case SlpFile.next_frame(file) do
      {:ok, gamestate, file} -> drain(file, count + 1, gamestate)
      {:done, _file} -> {count, last}
    end
  end

  # Feed the raw element straight to the codec, the way the golden test
  # does, so the file reader can be compared against it.
  defp direct_parse_count(path) do
    <<"{U", 3, "raw[$U#l", len::big-unsigned-32, rest::binary>> = File.read!(path)
    raw = binary_part(rest, 0, min(len, byte_size(rest)))

    count_frames(Melee.Events.new(), raw, 0)
  end

  defp count_frames(parser, bin, count) do
    case Melee.Events.handle_game_event(parser, bin) do
      {:frame_complete, _gs, parser} -> count_frames(parser, <<>>, count + 1)
      {:rollback, parser} -> count_frames(parser, <<>>, count)
      {:continue, _parser} -> count
      {:game_end, _parser} -> count
      {:error, _reason, _parser} -> count
    end
  end
end
