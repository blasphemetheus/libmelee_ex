defmodule Melee.SlpFile do
  @moduledoc """
  Read a `.slp` replay through the same decoder that drives live play.

  A replay's `raw` element is byte-identical to the spectator stream, so
  the events in a file and the events from Dolphin go through exactly the
  same `Melee.Events` codec. That makes a replay a deterministic stand-in
  for a live console: bot logic can be driven frame-by-frame offline,
  reproducibly, with no emulator.

  This is the port of libmelee's `slpfilestreamer.py`. For BULK replay
  parsing (feature extraction over thousands of files) a dedicated parser
  like [peppi](https://github.com/hohav/peppi) is the better tool — this
  module exists so a step loop can consume a file the way it consumes a
  game.

      Melee.SlpFile.stream!("game.slp")
      |> Stream.filter(&Melee.GameState.in_game?/1)
      |> Enum.each(&my_bot_logic/1)

  ## Old replays

  Slippi added FRAME_BOOKEND in replay version 2.2.0; before that
  nothing marks a frame boundary, so a naive read of an old file yields
  no frames at all. Like libmelee, this module falls back to "manual
  bookends" — watching the frame counter on PRE/POST_FRAME events and
  completing the previous frame when it advances — so pre-2.2.0 files
  stream correctly too. `metadata/1` reports which mode a file needs.
  """

  alias Melee.{Events, GameState}

  # Event command bytes we must recognise to detect frame advance.
  @payloads 0x35
  @pre_frame 0x37
  @post_frame 0x38
  @frame_bookend 0x3C

  @typedoc "An opened replay: decoded container plus decoder state."
  @type t :: %__MODULE__{
          path: Path.t(),
          raw: binary(),
          metadata: map(),
          parser: Events.Parser.t(),
          cursor: non_neg_integer(),
          sizes: %{non_neg_integer() => pos_integer()},
          manual_bookends: boolean(),
          last_frame: integer() | nil,
          seen: MapSet.t()
        }

  defstruct [
    :path,
    :raw,
    :metadata,
    :parser,
    cursor: 0,
    sizes: %{},
    manual_bookends: false,
    last_frame: nil,
    # {command, port, follower} tuples seen for the frame currently
    # accumulating (manual bookends only) — a repeat means a rollback
    # re-simulation of the same frame, which is its own frame boundary.
    seen: MapSet.new()
  ]

  @doc """
  Open a replay: unwrap the container, read its metadata, and decide
  whether manual bookends are needed.

  Options are passed to `Melee.Events.new/1` — notably
  `skip_rollback_frames: false` to see re-simulated frames.
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts \\ []) do
    with {:ok, content} <- File.read(path),
         {:ok, raw, metadata} <- unwrap(content) do
      {:ok,
       %__MODULE__{
         path: path,
         raw: raw,
         metadata: metadata,
         parser: Events.new(opts),
         manual_bookends: not has_bookends?(raw)
       }}
    end
  end

  @doc "Open a replay, raising on failure."
  @spec open!(Path.t(), keyword()) :: t()
  def open!(path, opts \\ []) do
    case open(path, opts) do
      {:ok, file} -> file
      {:error, reason} -> raise ArgumentError, "cannot open #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Stream a replay's frames as `Melee.GameState` structs, in order.

  The stream ends at GAME_END or when the events run out.
  """
  @spec stream!(Path.t(), keyword()) :: Enumerable.t()
  def stream!(path, opts \\ []) do
    Stream.resource(
      fn -> open!(path, opts) end,
      fn file ->
        case next_frame(file) do
          {:ok, gamestate, file} -> {[gamestate], file}
          {:done, file} -> {:halt, file}
        end
      end,
      fn _file -> :ok end
    )
  end

  @doc """
  Decode the next complete frame.

  Returns `{:ok, gamestate, file}`, or `{:done, file}` at GAME_END or
  end of data.
  """
  @spec next_frame(t()) :: {:ok, GameState.t(), t()} | {:done, t()}
  def next_frame(%__MODULE__{} = file) do
    # Anything the parser buffered from a previous chunk first.
    case Events.handle_game_event(file.parser, <<>>) do
      {:frame_complete, gamestate, parser} ->
        {:ok, gamestate, %{file | parser: parser}}

      {_other, parser} ->
        feed(%{file | parser: parser})

      {:error, _reason, parser} ->
        feed(%{file | parser: parser})
    end
  end

  @doc """
  A replay's metadata: `startAt`, `lastFrame`, `playedOn`, `players`
  (names/characters), plus `:manual_bookends` — whether the file predates
  FRAME_BOOKEND.
  """
  @spec metadata(Path.t()) :: {:ok, map()} | {:error, term()}
  def metadata(path) do
    with {:ok, content} <- File.read(path),
         {:ok, raw, metadata} <- unwrap(content) do
      {:ok, Map.put(metadata, :manual_bookends, not has_bookends?(raw))}
    end
  end

  ## Event feeding

  # Hand the decoder one event at a time, so a frame boundary can be
  # detected between events on files that have no bookends.
  defp feed(%__MODULE__{cursor: cursor, raw: raw} = file) when cursor >= byte_size(raw) do
    # Out of data: flush any frame still in progress (old files end
    # without a bookend).
    case Events.complete_frame(file.parser) do
      {:frame_complete, gamestate, parser} ->
        {:ok, gamestate, %{file | parser: parser, cursor: cursor + 1}}

      _ ->
        {:done, file}
    end
  end

  defp feed(%__MODULE__{} = file) do
    case take_event(file) do
      :eof ->
        feed(%{file | cursor: byte_size(file.raw)})

      {:ok, event, file} ->
        with {:manual, file} <- maybe_manual_bookend(file, event) do
          dispatch(file, event)
        else
          {:frame, gamestate, file} -> {:ok, gamestate, file}
        end
    end
  end

  defp dispatch(file, event) do
    case Events.handle_game_event(file.parser, event) do
      {:frame_complete, gamestate, parser} ->
        {:ok, gamestate, %{file | parser: parser}}

      {:game_end, parser} ->
        file = %{file | parser: parser, cursor: byte_size(file.raw)}

        # On a manual-bookend file the FINAL frame is still accumulating
        # when GAME_END arrives — there is no successor pre-frame to
        # complete it off. Flush it or it is silently dropped (found by
        # the peppi differential: every pre-2.2.0 replay came up exactly
        # one frame short). complete_frame is a no-op once flushed, so
        # the subsequent out-of-data flush cannot double-emit.
        if file.manual_bookends do
          case Events.complete_frame(file.parser) do
            {:frame_complete, gamestate, parser} ->
              {:ok, gamestate, %{file | parser: parser}}

            {_other, parser} ->
              {:done, %{file | parser: parser}}
          end
        else
          {:done, file}
        end

      {:rollback, parser} ->
        feed(%{file | parser: parser})

      {:continue, parser} ->
        feed(%{file | parser: parser})

      {:error, _reason, parser} ->
        feed(%{file | parser: parser})
    end
  end

  # On a pre-2.2.0 file, a frame boundary has to be inferred, exactly as
  # libmelee's streamer synthesizes a `frame_end` message:
  #
  #   * a PRE/POST_FRAME with a HIGHER frame number than the one
  #     accumulating means the previous frame is over;
  #   * a REPEAT of an already-seen (event, port, follower) for the SAME
  #     frame — or a LOWER frame number — means a rollback re-simulation
  #     is starting (observed in the wild: an early-rollback-era
  #     pre-2.2.0 replay carried frame 6176 twice; the peppi
  #     differential caught the merge). Completing the frame lets
  #     `Events.frame_bookend` apply its normal rollback semantics:
  #     re-simulations are dropped under `skip_rollback_frames: true`
  #     (the first simulation wins, as live) and emitted under `false`.
  #
  # The dedup key includes the follower byte: Ice Climbers emit a second
  # PRE/POST for the same port every frame (Nana), which must NOT read
  # as a re-simulation.
  defp maybe_manual_bookend(%__MODULE__{manual_bookends: false} = file, _event),
    do: {:manual, file}

  defp maybe_manual_bookend(file, <<command, frame::big-signed-32, port, rest::binary>>)
       when command in [@pre_frame, @post_frame] do
    follower =
      case rest do
        <<f, _::binary>> -> f
        _ -> 0
      end

    key = {command, port, follower}

    cond do
      file.last_frame == nil ->
        {:manual, %{file | last_frame: frame, seen: MapSet.new([key])}}

      frame > file.last_frame or frame < file.last_frame or MapSet.member?(file.seen, key) ->
        file = %{file | last_frame: frame, seen: MapSet.new()}

        case Events.complete_frame(file.parser) do
          {:frame_complete, gamestate, parser} ->
            # Rewind so this event is re-read for the NEW frame.
            {:frame, gamestate,
             %{file | parser: parser, cursor: file.cursor - event_size(file, command)}}

          {_other, parser} ->
            # Nothing to emit (or a skipped rollback re-simulation):
            # keep going, with this event opening the new accumulation.
            {:manual, %{file | parser: parser, seen: MapSet.new([key])}}
        end

      true ->
        {:manual, %{file | seen: MapSet.put(file.seen, key)}}
    end
  end

  defp maybe_manual_bookend(file, _event), do: {:manual, file}

  defp event_size(file, command), do: Map.get(file.sizes, command, 1)

  # Slice one event off the raw stream, tracking the payload-size table.
  defp take_event(%__MODULE__{raw: raw, cursor: cursor} = file) do
    case raw do
      <<_::binary-size(cursor), @payloads, payload_size, _::binary>> ->
        size = payload_size + 1
        event = binary_part(raw, cursor, min(size, byte_size(raw) - cursor))
        {:ok, event, %{file | cursor: cursor + size, sizes: parse_sizes(event)}}

      <<_::binary-size(cursor), command, _::binary>> ->
        case Map.fetch(file.sizes, command) do
          {:ok, size} when cursor + size <= byte_size(raw) ->
            {:ok, binary_part(raw, cursor, size), %{file | cursor: cursor + size}}

          {:ok, _size} ->
            :eof

          :error ->
            # Zero padding or an unknown command: skip a byte and resync,
            # the same tolerance the live decoder has.
            {:ok, <<>>, %{file | cursor: cursor + 1}}
        end

      _ ->
        :eof
    end
  end

  defp parse_sizes(<<@payloads, payload_size, table::binary>>) do
    count = div(payload_size - 1, 3)
    slice = binary_part(table, 0, min(count * 3, byte_size(table)))

    for <<command, len::big-unsigned-16 <- slice>>, into: %{} do
      {command, len + 1}
    end
  end

  defp parse_sizes(_), do: %{}

  ## Container

  # `{U\x03raw[$U#l<len><raw><metadata...>` — UBJSON with a
  # length-prefixed raw element.
  defp unwrap(<<"{U", 3, "raw[$U#l", len::big-unsigned-32, rest::binary>>) do
    take = min(len, byte_size(rest))
    raw = binary_part(rest, 0, take)
    tail = binary_part(rest, take, byte_size(rest) - take)
    {:ok, raw, parse_metadata(tail)}
  end

  defp unwrap(_), do: {:error, :not_an_slp_file}

  # Enough UBJSON to lift the flat metadata values libmelee exposes.
  # Deliberately minimal: this is a convenience, not a UBJSON library.
  defp parse_metadata(tail) do
    %{
      startAt: ubjson_string(tail, "startAt"),
      playedOn: ubjson_string(tail, "playedOn"),
      consoleNick: ubjson_string(tail, "consoleNick"),
      lastFrame: ubjson_i32(tail, "lastFrame"),
      players: player_names(tail)
    }
  end

  defp ubjson_string(bin, key) do
    pattern = <<0x55, byte_size(key), key::binary, ?S, 0x55>>

    case :binary.match(bin, pattern) do
      :nomatch ->
        nil

      {idx, len} ->
        <<value_len>> = binary_part(bin, idx + len, 1)
        binary_part(bin, idx + len + 1, value_len)
    end
  end

  defp ubjson_i32(bin, key) do
    pattern = <<0x55, byte_size(key), key::binary, ?l>>

    case :binary.match(bin, pattern) do
      :nomatch ->
        nil

      {idx, len} ->
        <<value::big-signed-32>> = binary_part(bin, idx + len, 4)
        value
    end
  end

  defp player_names(bin) do
    for port <- 0..3, into: %{} do
      pattern = <<0x55, 1, ?0 + port, ?{, 0x55, 5, "names", ?{, 0x55, 7, "netplay", ?S, 0x55>>

      name =
        case :binary.match(bin, pattern) do
          :nomatch ->
            ""

          {idx, len} ->
            <<name_len>> = binary_part(bin, idx + len, 1)
            binary_part(bin, idx + len + 1, name_len)
        end

      {port + 1, name}
    end
  end

  defp has_bookends?(raw) do
    case :binary.match(raw, <<@payloads>>) do
      :nomatch ->
        false

      {idx, _} ->
        <<_::binary-size(idx), @payloads, payload_size, table::binary>> = raw
        count = div(payload_size - 1, 3)
        slice = binary_part(table, 0, min(count * 3, byte_size(table)))
        commands = for <<command, _::big-16 <- slice>>, do: command
        @frame_bookend in commands
    end
  end
end
