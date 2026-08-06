defmodule Melee.RollbackTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Rollback semantics: what happens when Slippi re-simulates a frame.

  Netplay Dolphin rolls back and replays frames when a remote input
  arrives late, and it emits the re-simulated frames on the spectator
  stream. Two consumers want opposite things:

    * a live bot wants the newest state once — `skip_rollback_frames:
      true` (the default, matching libmelee)
    * a training pipeline reconstructing exactly what the game computed
      wants every emission — `skip_rollback_frames: false`
      (slippi-ai's harness reads replays this way, and the peppi
      differential confirmed peppi emits a row per re-simulation:
      both parsers produce the identical 9,119-frame sequence for a
      netplay replay only in this mode)

  The skip path also has a liveness obligation: under blocking input
  Dolphin waits for controller input on the re-simulated frame too, so a
  skipped frame must still flush controllers or the game hangs.
  """

  alias Melee.{Console, Events, Slippstream}

  ## --- wire builders (same shape as events_test) ---------------------

  defp u8(v), do: <<v>>
  defp u16(v), do: <<v::big-unsigned-16>>
  defp i32(v), do: <<v::big-signed-32>>
  defp f32(v), do: <<v::big-float-32>>

  defp event(command, size, fields) do
    base = <<command>> <> :binary.copy(<<0>>, size - 1)

    Enum.reduce(Map.new(fields), base, fn {off, value}, acc ->
      after_start = off + byte_size(value)

      binary_part(acc, 0, off) <>
        value <> binary_part(acc, after_start, byte_size(acc) - after_start)
    end)
  end

  @sizes %{0x36 => 0x2ED, 0x37 => 0x41, 0x38 => 0x85, 0x39 => 0x2, 0x3B => 0x2C, 0x3C => 0x9}

  defp payloads do
    table = for {cmd, size} <- @sizes, into: <<>>, do: <<cmd, size - 1::big-unsigned-16>>
    <<0x35, byte_size(table) + 1>> <> table
  end

  defp game_start do
    event(0x36, @sizes[0x36], %{
      0x1 => u8(3),
      0x2 => u8(16),
      0x13 => u16(0x20),
      0x66 => u8(0),
      (0x66 + 0x24) => u8(0)
    })
  end

  # `x` distinguishes re-simulations of the SAME frame number, which is
  # the whole point: a rollback re-emits frame N with different values.
  defp frame(n, x \\ 0.0) do
    event(0x37, @sizes[0x37], %{0x1 => i32(n), 0x5 => u8(0)}) <>
      event(0x38, @sizes[0x38], %{
        0x1 => i32(n),
        0x5 => u8(0),
        0x7 => u8(0x1),
        0x8 => u16(14),
        0xA => f32(x)
      }) <>
      event(0x3C, @sizes[0x3C], %{0x1 => i32(n)})
  end

  defp connected_parser(opts \\ []) do
    parser = Events.new(opts)
    {:continue, parser} = Events.handle_game_event(parser, payloads())
    {:continue, parser} = Events.handle_game_event(parser, game_start())
    parser
  end

  # Feed a stream and collect every result the parser produces.
  defp collect(parser, bin, acc \\ []) do
    case Events.handle_game_event(parser, bin) do
      {:frame_complete, gs, parser} -> collect(parser, <<>>, [{:frame, gs} | acc])
      {:rollback, parser} -> collect(parser, <<>>, [:rollback | acc])
      {:continue, %{pending: <<>>}} -> Enum.reverse(acc)
      {:continue, parser} -> collect(parser, <<>>, acc)
      {:game_end, _parser} -> Enum.reverse([:game_end | acc])
      {:error, reason, _parser} -> Enum.reverse([{:error, reason} | acc])
    end
  end

  ## --- decoder semantics ---------------------------------------------

  describe "skip_rollback_frames: true (default)" do
    test "a re-simulated frame is signalled and dropped, keeping the FIRST emission" do
      parser = connected_parser()

      results =
        collect(parser, frame(100, 10.0) <> frame(100, 99.0) <> frame(101, 11.0))

      assert [{:frame, first}, :rollback, {:frame, next}] = results

      assert first.frame == 100
      assert first.players[1].position.x == 10.0, "the first emission is the one delivered"
      assert next.frame == 101
    end

    test "a whole rollback window is dropped, not just one frame" do
      parser = connected_parser()

      # Frames 50..52 play out, then the game rolls back to 51 and
      # re-simulates 51, 52, 53.
      stream =
        frame(50) <>
          frame(51) <>
          frame(52) <>
          frame(51, 5.0) <>
          frame(52, 5.0) <>
          frame(53, 5.0)

      results = collect(parser, stream)
      delivered = for {:frame, gs} <- results, do: gs.frame

      assert delivered == [50, 51, 52, 53]
      assert Enum.count(results, &(&1 == :rollback)) == 2
    end

    test "a new game restarts the frame clock without being mistaken for rollback" do
      # Melee restarts at -123, far BELOW the previous game's frames, so
      # a naive `frame <= last_frame` check would discard the whole new
      # game as re-simulated. GAME_START has to reset the counter — and
      # this must be checked on the SAME parser that played the old game,
      # or it proves nothing.
      parser = connected_parser()

      # Play the first game out to frame 500.
      parser =
        Enum.reduce([400, 500], parser, fn n, parser ->
          {:frame_complete, _gs, parser} = Events.handle_game_event(parser, frame(n))
          parser
        end)

      assert parser.frame == 500

      # Second game on the same connection.
      results = collect(parser, game_start() <> frame(-123) <> frame(-122))

      assert [{:frame, a}, {:frame, b}] = results,
             "the new game's early frames were swallowed as rollbacks"

      assert a.frame == -123
      assert b.frame == -122
    end
  end

  describe "skip_rollback_frames: false" do
    test "every emission is delivered, including re-simulations" do
      parser = connected_parser(skip_rollback_frames: false)

      results = collect(parser, frame(100, 10.0) <> frame(100, 99.0) <> frame(101, 11.0))

      assert [{:frame, a}, {:frame, b}, {:frame, c}] = results
      assert Enum.map([a, b, c], & &1.frame) == [100, 100, 101]

      # The re-simulation carries DIFFERENT values — that is why a
      # training pipeline wants it.
      assert a.players[1].position.x == 10.0
      assert b.players[1].position.x == 99.0
    end

    test "no :rollback signal is produced" do
      parser = connected_parser(skip_rollback_frames: false)
      results = collect(parser, frame(7) <> frame(7) <> frame(7))

      refute :rollback in results
      assert length(results) == 3
    end

    test "delivers at least as many frames as the skipping mode" do
      stream = frame(1) <> frame(1) <> frame(2) <> frame(2) <> frame(3)

      skipped = collect(connected_parser(), stream)
      kept = collect(connected_parser(skip_rollback_frames: false), stream)

      assert length(for {:frame, _} <- skipped, do: 1) == 3
      assert length(for {:frame, _} <- kept, do: 1) == 5
    end
  end

  ## --- console liveness ----------------------------------------------

  defmodule RelayTransport do
    @moduledoc false
    @behaviour Melee.Transport

    @impl true
    def connect(_host, _port, owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:transport_connect, owner})
      {:ok, {:relay, test_pid}}
    end

    @impl true
    def send({:relay, test_pid}, channel, data, :reliable) do
      send(test_pid, {:transport_send, channel, data})
      :ok
    end

    @impl true
    def disconnect({:relay, _test_pid}), do: :ok
  end

  defp connected_console(opts) do
    {:ok, console} =
      Console.start_link(
        Keyword.merge([transport: RelayTransport, transport_opts: [test_pid: self()]], opts)
      )

    task = Task.async(fn -> Console.connect(console, 5_000) end)
    assert_receive {:transport_connect, owner}
    send(owner, {:enet_connected, {:relay, self()}})
    assert :ok = Task.await(task, 5_000)
    assert_receive {:transport_send, 0, handshake}
    assert handshake == Slippstream.connect_request()

    {console, owner}
  end

  defp inject(owner, bin) do
    packet = Jason.encode!(%{"type" => "game_event", "payload" => Base.encode64(bin)})
    send(owner, {:enet_packet, {:relay, self()}, 0, packet})
  end

  defp file_controller(ctx) do
    path = Path.join(System.tmp_dir!(), "rollback_ctl_#{:erlang.phash2(ctx.test)}")
    File.rm(path)
    {:ok, pid} = Melee.Controller.start_link(pipe_path: path)
    :ok = Melee.Controller.connect(pid)
    on_exit(fn -> File.rm(path) end)
    {pid, path}
  end

  describe "blocking input" do
    test "a skipped rollback frame still flushes controllers", ctx do
      # Under blocking input Dolphin waits for input on the re-simulated
      # frame too. Dropping it WITHOUT flushing hangs the game — this is
      # the liveness half of rollback handling.
      {console, owner} = connected_console(blocking_input: true)
      {controller, path} = file_controller(ctx)
      :ok = Console.register_controller(console, controller)

      inject(owner, payloads() <> game_start() <> frame(10))
      assert {:ok, _} = Console.step(console, 5_000)

      flushes_before = count_flushes(path)

      # A re-simulation of frame 10: no frame is delivered, so the caller
      # never gets a chance to flush — the console must do it.
      inject(owner, frame(10, 1.0))
      inject(owner, frame(11))
      assert {:ok, gs} = Console.step(console, 5_000)
      assert gs.frame == 11

      assert count_flushes(path) > flushes_before,
             "a skipped rollback frame must still flush, or blocking-input Dolphin hangs"
    end

    test "with blocking_input: false a skipped frame does not flush", ctx do
      {console, owner} = connected_console(blocking_input: false)
      {controller, path} = file_controller(ctx)
      :ok = Console.register_controller(console, controller)

      inject(owner, payloads() <> game_start() <> frame(10))
      assert {:ok, _} = Console.step(console, 5_000)

      flushes_before = count_flushes(path)

      # Deliver the rollback and the next frame in ONE packet so the
      # step/2 that returns frame 11 cannot be credited with the flush.
      inject(owner, frame(10, 1.0) <> frame(11))
      assert {:ok, %{frame: 11}} = Console.step(console, 5_000)

      # step/2 flushes once at the top; the rollback adds nothing.
      assert count_flushes(path) - flushes_before <= 1
    end
  end

  defp count_flushes(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.split("FLUSH") |> length() |> Kernel.-(1)
      _ -> 0
    end
  end
end
