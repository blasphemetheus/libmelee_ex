defmodule Melee.EventsGoldenTest do
  use ExUnit.Case, async: true

  alias Melee.Events

  @moduledoc """
  Golden test against a real Slippi replay.

  A `.slp` file's `raw` element is byte-identical to the live spectator
  event stream (same PAYLOADS table, same events), so parsing it
  exercises the codec on real bytes. Fixture: a local Fox multishine
  recording from exphil.
  """

  @fixture Path.expand("../fixtures/fox_multishine.slp", __DIR__)

  # The .slp container is UBJSON: `{U\x03raw[$U#l` + u32 length + raw stream.
  defp raw_stream! do
    <<"{U", 3, "raw[$U#l", len::big-unsigned-32, raw::binary-size(len), _::binary>> =
      File.read!(@fixture)

    raw
  end

  defp collect_frames(parser, chunks, acc \\ [])
  defp collect_frames(_parser, [], acc), do: {Enum.reverse(acc), :out_of_data}

  defp collect_frames(parser, [chunk | rest], acc) do
    case Events.handle_game_event(parser, chunk) do
      {:frame_complete, gs, parser} -> collect_frames(parser, [<<>> | rest], [gs | acc])
      {:continue, %{pending: <<>>} = parser} -> collect_frames(parser, rest, acc)
      {:continue, parser} -> collect_frames(parser, rest, acc)
      {:game_end, _parser} -> {Enum.reverse(acc), :game_end}
      {:error, reason, _parser} -> {Enum.reverse(acc), {:error, reason}}
    end
  end

  test "parses a full real replay to game end" do
    raw = raw_stream!()
    {frames, outcome} = collect_frames(Events.new(), [raw])

    assert outcome == :game_end
    assert length(frames) > 1000

    first = hd(frames)
    last = List.last(frames)

    # Frames are monotonically increasing, starting in the pre-GO countdown.
    assert first.frame < 0
    frame_numbers = Enum.map(frames, & &1.frame)
    assert frame_numbers == Enum.sort(frame_numbers)
    assert length(Enum.uniq(frame_numbers)) == length(frame_numbers)

    # Fox multishine: at least one Fox (internal id 0x01) on the field the whole game.
    assert Enum.any?(first.players, fn {_port, p} -> p.character == 0x01 end)
    assert Enum.any?(last.players, fn {_port, p} -> p.character == 0x01 end)

    # Stage is a real internal stage id.
    assert Melee.Enums.Stage.valid?(last.stage)

    # Every frame has sane physics values.
    for gs <- Enum.take_every(frames, 100), {_port, p} <- gs.players do
      assert p.percent >= 0.0
      assert p.stock in 0..4
      assert p.shield_strength >= 0.0 and p.shield_strength <= 60.0
      {mx, my} = p.controller_state.main_stick
      assert mx >= 0.0 and mx <= 1.0
      assert my >= 0.0 and my <= 1.0
    end
  end

  test "chunked delivery (simulating enet packets) parses identically" do
    raw = raw_stream!()

    # Whole-stream parse
    {frames_whole, :game_end} = collect_frames(Events.new(), [raw])

    # 1000-byte chunks, arbitrary event boundaries
    chunks = for <<chunk::binary-size(1000) <- raw>>, do: chunk
    leftover_start = length(chunks) * 1000
    leftover = binary_part(raw, leftover_start, byte_size(raw) - leftover_start)
    {frames_chunked, :game_end} = collect_frames(Events.new(), chunks ++ [leftover])

    assert length(frames_whole) == length(frames_chunked)
    assert frames_whole == frames_chunked
  end
end
