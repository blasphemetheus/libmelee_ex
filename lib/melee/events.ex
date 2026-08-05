defmodule Melee.Events do
  @moduledoc """
  Pure decoder for the Slippi binary event stream.

  This is the heart of the port: a functional translation of libmelee's
  `Console.__handle_slippstream_events`. All multi-byte fields are
  big-endian. Event sizes are self-described by the `0x35 PAYLOADS`
  event, which must be parsed before any other event can be sliced.

  The decoder is driven through a `Melee.Events.Parser` struct that
  carries the state libmelee keeps on its `Console` object (payload
  size table, SLP version, per-port metadata from GAME_START, last
  completed frame, previous frame's players for the moonwalk warning).

  Fields absent in older SLP versions (shorter events) read as their
  libmelee defaults instead of raising — the binary size guards here
  play the role of Python's `except TypeError` fallbacks.
  """

  alias Melee.{
    ECB,
    FoDPlatforms,
    FrameData,
    GameState,
    PlayerState,
    Position,
    Projectile,
    StadiumTransformation
  }

  alias Melee.Events.Menu

  import Bitwise

  # Event command bytes (slippstream.py EventType)
  @gecko_codes 0x10
  @payloads 0x35
  @game_start 0x36
  @pre_frame 0x37
  @post_frame 0x38
  @game_end 0x39
  @frame_start 0x3A
  @item_update 0x3B
  @frame_bookend 0x3C
  @gecko_list 0x3D
  @menu_event 0x3E
  @fod_info 0x3F
  @dl_info 0x40
  @ps_info 0x41
  @bones 0x60

  # Menu enum wire values used internally
  @menu_in_game 2

  # Stage internal ids (enums.Stage)
  @stage_fountain 0x8
  @stage_stadium 0x12
  @stage_dreamland 0x1A

  # Action enum bounds for the IASA fix (NEUTRAL_ATTACK_1..DAIR)
  @action_neutral_attack_1 44
  @action_dair 71
  @action_dashing 20
  @action_turning 18

  defmodule Parser do
    @moduledoc """
    Decoder state carried across events and frames.

    Mirrors the persistent parts of libmelee's `Console`: the payload
    size table, SLP version, GAME_START per-port metadata, the last
    completed frame number, and the previous frame's players.
    """

    @type t :: %__MODULE__{
            pending: binary(),
            game_started: boolean(),
            payload_sizes: %{non_neg_integer() => pos_integer()},
            slp_version: {integer(), integer(), integer()},
            current_stage: integer(),
            is_teams: boolean(),
            is_frozen_ps: boolean(),
            costumes: tuple(),
            cpu_levels: tuple(),
            team_ids: tuple(),
            display_names: tuple(),
            connect_codes: tuple(),
            frame: integer(),
            skip_rollback_frames: boolean(),
            prev_players: %{integer() => Melee.PlayerState.t()},
            fod_platforms: Melee.FoDPlatforms.t() | nil,
            whispy: integer() | nil,
            stadium_transformation: Melee.StadiumTransformation.t() | nil,
            gamestate: Melee.GameState.t()
          }

    defstruct pending: <<>>,
              game_started: false,
              payload_sizes: %{},
              slp_version: {0, 0, 0},
              current_stage: 0,
              is_teams: false,
              is_frozen_ps: false,
              costumes: {0, 0, 0, 0},
              cpu_levels: {0, 0, 0, 0},
              team_ids: {0, 0, 0, 0},
              display_names: {"", "", "", ""},
              connect_codes: {"", "", "", ""},
              frame: -10_000,
              skip_rollback_frames: true,
              prev_players: %{},
              fod_platforms: nil,
              whispy: nil,
              stadium_transformation: nil,
              gamestate: %Melee.GameState{}
  end

  @type result ::
          {:frame_complete, GameState.t(), Parser.t()}
          | {:continue, Parser.t()}
          | {:rollback, Parser.t()}
          | {:game_end, Parser.t()}
          | {:error, term(), Parser.t()}

  @doc "Create a fresh parser. Options: `skip_rollback_frames` (default true)."
  @spec new(keyword()) :: Parser.t()
  def new(opts \\ []) do
    %Parser{skip_rollback_frames: Keyword.get(opts, :skip_rollback_frames, true)}
  end

  @doc """
  Clear the `game_started` flag.

  The flag is set when a GAME_START event is parsed; libmelee reacts to
  it by flushing empty controller input (characters aren't actionable on
  frame one, but the game needs *something* pressed). `Melee.Console`
  reads and clears it via this function.
  """
  @spec clear_game_started(Parser.t()) :: Parser.t()
  def clear_game_started(%Parser{} = parser), do: %{parser | game_started: false}

  @doc """
  Process one decoded `game_event` payload (a run of binary Slippi events).

  Returns `{:frame_complete, gamestate, parser}` when a frame bookend
  completed a fresh frame, `{:continue, parser}` when more data is needed
  (including skipped rollback frames), `{:game_end, parser}` after a
  GAME_END event finished the stream, or `{:error, reason, parser}`.

  Unlike Python libmelee (which warns and drops), events left over after
  a completed frame are kept in the parser's `pending` buffer and picked
  up on the next call — call with `<<>>` to drain buffered events without
  new data.
  """
  @spec handle_game_event(Parser.t(), binary()) :: result()
  def handle_game_event(%Parser{} = parser, bin) when is_binary(bin) do
    parser = put_in_menu_state(parser, @menu_in_game)
    bin = parser.pending <> bin
    walk(%{parser | pending: <<>>}, bin)
  end

  @doc """
  Process one decoded `menu_event` payload.

  Always completes a frame: returns `{:frame_complete, gamestate, parser}`.
  """
  @spec handle_menu_event(Parser.t(), binary()) :: {:frame_complete, GameState.t(), Parser.t()}
  def handle_menu_event(%Parser{} = parser, bin) when is_binary(bin) do
    gamestate = Menu.parse(bin, parser.gamestate)
    {:frame_complete, gamestate, %{parser | gamestate: %GameState{}}}
  end

  ## Event walk

  defp walk(parser, <<>>), do: {:continue, parser}

  # PAYLOADS: self-describing size table. Sizes stored include the command byte.
  defp walk(parser, <<@payloads, payload_size, _rest::binary>> = bin)
       when byte_size(bin) > payload_size do
    num_commands = div(payload_size - 1, 3)
    table = binary_part(bin, 2, num_commands * 3)

    sizes =
      for <<command, len::big-16 <- table>>, into: parser.payload_sizes do
        {command, len + 1}
      end

    rest = binary_part(bin, payload_size + 1, byte_size(bin) - payload_size - 1)
    walk(%{parser | payload_sizes: sizes}, rest)
  end

  # Menu event mid-stream: dolphin bug — treat as a completed menu frame.
  defp walk(parser, <<@menu_event, _::binary>> = bin) do
    handle_menu_event(parser, bin)
  end

  defp walk(parser, <<command, _::binary>> = bin) do
    case Map.fetch(parser.payload_sizes, command) do
      :error ->
        {:error, {:unknown_event, command}, parser}

      {:ok, size} when byte_size(bin) < size ->
        # Partial event: buffer it until the rest arrives (Python drops it).
        {:continue, %{parser | pending: bin}}

      {:ok, size} ->
        event = binary_part(bin, 0, size)
        rest = binary_part(bin, size, byte_size(bin) - size)

        case dispatch(parser, command, event) do
          {:cont, parser} ->
            walk(parser, rest)

          {:halt, {:frame_complete, gamestate, parser}} ->
            {:frame_complete, gamestate, %{parser | pending: rest}}

          {:halt, {:rollback, parser}} ->
            {:rollback, %{parser | pending: rest}}

          {:halt, result} ->
            result
        end
    end
  end

  ## Dispatch

  defp dispatch(parser, @game_start, event), do: {:cont, game_start(parser, event)}
  defp dispatch(parser, @game_end, _event), do: {:halt, {:game_end, parser}}
  defp dispatch(parser, @pre_frame, event), do: {:cont, pre_frame(parser, event)}
  defp dispatch(parser, @post_frame, event), do: {:cont, post_frame(parser, event)}
  defp dispatch(parser, @item_update, event), do: {:cont, item_update(parser, event)}
  defp dispatch(parser, @fod_info, event), do: {:cont, fod_platforms(parser, event)}
  defp dispatch(parser, @dl_info, event), do: {:cont, whispy_blow(parser, event)}
  defp dispatch(parser, @ps_info, event), do: {:cont, stadium_transformation(parser, event)}
  defp dispatch(parser, @frame_bookend, event), do: frame_bookend(parser, event)

  defp dispatch(parser, command, _event)
       when command in [@frame_start, @gecko_codes, @gecko_list, @bones],
       do: {:cont, parser}

  defp dispatch(parser, command, _event), do: {:halt, {:error, {:unhandled_event, command}, parser}}

  ## GAME_START (0x36)

  defp game_start(parser, event) do
    <<_cmd, major, minor, patch, _::binary>> = event
    version = {major, minor, patch}

    # GAME_START carries the external stage id; convert to the internal id
    # that Stage enums (and the rest of this library) use.
    current_stage =
      event
      |> read_u16(0x13, 0)
      |> Melee.Enums.Stage.from_external()
      |> Melee.Enums.Stage.to_id()

    is_teams = read_u16(event, 0xD, 0) != 0

    read4 = fn base, stride ->
      List.to_tuple(for i <- 0..3, do: read_u8(event, base + stride * i, 0))
    end

    costumes = read4.(0x68, 0x24)
    team_ids = read4.(0x6E, 0x24)

    cpu_levels =
      List.to_tuple(
        for i <- 0..3 do
          # Player type 1 = CPU; otherwise cpu_level is meaningless.
          if read_u8(event, 0x66 + 0x24 * i, 0) == 1 do
            read_u8(event, 0x74 + 0x24 * i, 0)
          else
            0
          end
        end
      )

    is_frozen_ps = version >= {2, 0, 0} and read_u8(event, 0x1A2, 0) != 0

    {display_names, connect_codes} =
      if version >= {3, 9, 0} do
        {
          List.to_tuple(for i <- 0..3, do: Melee.ShiftJIS.read(event, 0x1A5 + 0x1F * i)),
          List.to_tuple(for i <- 0..3, do: Melee.ShiftJIS.read(event, 0x221 + 0xA * i))
        }
      else
        {parser.display_names, parser.connect_codes}
      end

    stage_state =
      case current_stage do
        @stage_fountain -> %{fod_platforms: %FoDPlatforms{}, whispy: nil, stadium_transformation: nil}
        @stage_dreamland -> %{fod_platforms: nil, whispy: 0, stadium_transformation: nil}
        @stage_stadium -> %{fod_platforms: nil, whispy: nil, stadium_transformation: %StadiumTransformation{}}
        _ -> %{fod_platforms: nil, whispy: nil, stadium_transformation: nil}
      end

    %{
      parser
      | slp_version: version,
        current_stage: current_stage,
        is_teams: is_teams,
        costumes: costumes,
        cpu_levels: cpu_levels,
        team_ids: team_ids,
        is_frozen_ps: is_frozen_ps,
        display_names: display_names,
        connect_codes: connect_codes,
        frame: -10_000,
        game_started: true
    }
    |> Map.merge(stage_state)
  end

  ## PRE_FRAME (0x37)

  defp pre_frame(parser, event) do
    frame = read_i32(event, 0x1, -10_000)
    port = read_u8(event, 0x5, 0) + 1
    is_nana = read_u8(event, 0x6, 0) == 1

    gamestate = %{parser.gamestate | frame: frame}
    {player, gamestate} = fetch_player(gamestate, port)

    i = port - 1

    base = %{
      costume: elem(parser.costumes, i),
      cpu_level: elem(parser.cpu_levels, i),
      team_id: elem(parser.team_ids, i)
    }

    controller = %Melee.ControllerState{
      main_stick: {read_f32(event, 0x19, 0.0) / 2 + 0.5, read_f32(event, 0x1D, 0.0) / 2 + 0.5},
      c_stick: {read_f32(event, 0x21, 0.0) / 2 + 0.5, read_f32(event, 0x25, 0.0) / 2 + 0.5},
      raw_main_stick: {read_i8(event, 0x3B, 0), read_i8(event, 0x40, 0)},
      l_shoulder: read_f32(event, 0x29, 0.0),
      r_shoulder: read_f32(event, 0x29, 0.0),
      button: button_bits(read_u16(event, 0x31, 0)),
      processed_button: button_bits(read_u32(event, 0x2D, 0))
    }

    updated = struct!(target(player, is_nana), Map.put(base, :controller_state, controller))
    gamestate = put_player(gamestate, port, merge_nana(player, is_nana, updated))
    %{parser | gamestate: gamestate}
  end

  defp button_bits(bits) do
    %{
      a: (bits &&& 0x0100) != 0,
      b: (bits &&& 0x0200) != 0,
      x: (bits &&& 0x0400) != 0,
      y: (bits &&& 0x0800) != 0,
      start: (bits &&& 0x1000) != 0,
      z: (bits &&& 0x0010) != 0,
      r: (bits &&& 0x0020) != 0,
      l: (bits &&& 0x0040) != 0,
      d_left: (bits &&& 0x0001) != 0,
      d_right: (bits &&& 0x0002) != 0,
      d_down: (bits &&& 0x0004) != 0,
      d_up: (bits &&& 0x0008) != 0
    }
  end

  ## POST_FRAME (0x38)

  defp post_frame(parser, event) do
    port = read_u8(event, 0x5, 0) + 1
    is_nana = read_u8(event, 0x6, 0) == 1

    gamestate = %{
      parser.gamestate
      | stage: parser.current_stage,
        is_teams: parser.is_teams
    }

    {player, gamestate} = fetch_player(gamestate, port)
    target = target(player, is_nana)

    x = read_f32(event, 0xA, 0.0)
    y = read_f32(event, 0xE, 0.0)
    action = read_u16(event, 0x8, -1)
    on_ground = read_u8(event, 0x2F, 0) == 0

    off_stage =
      case Melee.Stages.edge_ground_position(gamestate.stage) do
        nil -> false
        edge -> (abs(x) > edge or y < -6) and not on_ground
      end

    prev_action = prev_action(parser, port)

    moonwalk =
      cond do
        action != @action_dashing -> false
        prev_action == nil -> target.moonwalkwarning
        prev_action not in [@action_dashing, @action_turning] -> true
        true -> target.moonwalkwarning
      end

    updated = %{
      target
      | position: %Position{x: x, y: y},
        character: read_u8(event, 0x7, 0xFF),
        action: action,
        facing: read_f32(event, 0x12, 1.0) > 0,
        percent: read_f32(event, 0x16, 0.0),
        shield_strength: read_f32(event, 0x1A, 60.0),
        stock: read_u8(event, 0x21, 0),
        action_frame: trunc(read_f32(event, 0x22, 0.0)),
        is_powershield: (read_u8(event, 0x29, 0) &&& 0x20) == 0x20,
        hitstun_frames_left: trunc(read_f32(event, 0x2B, 0.0)),
        on_ground: on_ground,
        jumps_left: read_u8(event, 0x32, 1),
        invulnerable: read_u8(event, 0x34, 0) != 0,
        speed_air_x_self: read_f32(event, 0x35, 0.0),
        speed_y_self: read_f32(event, 0x39, 0.0),
        speed_x_attack: read_f32(event, 0x3D, 0.0),
        speed_y_attack: read_f32(event, 0x41, 0.0),
        speed_ground_x_self: read_f32(event, 0x45, 0.0),
        hitlag_left: trunc(read_f32(event, 0x49, 0.0)),
        moonwalkwarning: moonwalk,
        off_stage: off_stage,
        ecb: %ECB{
          top: %Position{x: read_f32(event, 0x4D, 0.0), y: read_f32(event, 0x51, 0.0)},
          bottom: %Position{x: read_f32(event, 0x55, 0.0), y: read_f32(event, 0x59, 0.0)},
          left: %Position{x: read_f32(event, 0x5D, 0.0), y: read_f32(event, 0x61, 0.0)},
          right: %Position{x: read_f32(event, 0x65, 0.0), y: read_f32(event, 0x69, 0.0)}
        }
    }

    gamestate = put_player(gamestate, port, merge_nana(player, is_nana, updated))
    %{parser | gamestate: gamestate}
  end

  defp prev_action(parser, port) do
    case Map.fetch(parser.prev_players, port) do
      {:ok, player} -> player.action
      :error -> nil
    end
  end

  ## ITEM_UPDATE (0x3B)

  defp item_update(parser, event) do
    owner =
      if parser.slp_version >= {3, 6, 0} do
        read_i8(event, 0x2A, -2) + 1
      else
        -1
      end

    projectile = %Projectile{
      position: %Position{x: read_f32(event, 0x14, 0.0), y: read_f32(event, 0x18, 0.0)},
      speed: %Position{x: read_f32(event, 0xC, 0.0), y: read_f32(event, 0x10, 0.0)},
      type: read_u16(event, 0x5, 0xFFFF),
      expiration_frames: trunc(read_f32(event, 0x1E, 0.0)) * 1.0,
      subtype: read_u8(event, 0x7, 0),
      spawn_id: read_u32(event, 0x22, 0),
      owner: owner
    }

    gamestate = parser.gamestate
    %{parser | gamestate: %{gamestate | projectiles: gamestate.projectiles ++ [projectile]}}
  end

  ## Stage events

  defp fod_platforms(%{fod_platforms: nil} = parser, _event), do: parser

  defp fod_platforms(parser, event) do
    height = read_f32(event, 0x6, 0.0)

    platforms =
      case read_u8(event, 0x5, 255) do
        0 -> %{parser.fod_platforms | right: height}
        1 -> %{parser.fod_platforms | left: height}
        _ -> parser.fod_platforms
      end

    %{parser | fod_platforms: platforms}
  end

  defp whispy_blow(%{whispy: nil} = parser, _event), do: parser
  defp whispy_blow(parser, event), do: %{parser | whispy: read_u8(event, 0x5, 0)}

  defp stadium_transformation(%{stadium_transformation: nil} = parser, _event), do: parser

  defp stadium_transformation(parser, event) do
    %{
      parser
      | stadium_transformation: %StadiumTransformation{
          event: read_u8(event, 0x5, 0),
          type: read_u16(event, 0x7, 5)
        }
    }
  end

  ## FRAME_BOOKEND (0x3C)

  defp frame_bookend(parser, _event) do
    gamestate = parser.gamestate
    gamestate = %{gamestate | distance: distance(gamestate)}
    parser = %{parser | prev_players: gamestate.players}

    if gamestate.frame <= parser.frame and parser.skip_rollback_frames do
      # Old (rollback re-simulated) frame: discard. Tagged :rollback so
      # Melee.Console can flush controllers in blocking-input mode.
      {:halt, {:rollback, %{parser | gamestate: %GameState{}}}}
    else
      parser = %{parser | frame: gamestate.frame}
      gamestate = finalize(parser, gamestate)
      {:halt, {:frame_complete, gamestate, %{parser | gamestate: %GameState{}}}}
    end
  end

  defp distance(%GameState{players: players}) do
    case players |> Enum.sort_by(fn {port, _} -> port end) |> Enum.take(2) do
      [{_, p1}, {_, p2}] ->
        dx = p1.position.x - p2.position.x
        dy = p1.position.y - p2.position.y
        :math.sqrt(dx * dx + dy * dy)

      _ ->
        0.0
    end
  end

  # Per-frame post-fixes and metadata, mirroring the tail of Console.step.
  defp finalize(parser, gamestate) do
    players =
      Map.new(gamestate.players, fn {port, player} ->
        i = port - 1

        player =
          player
          |> fix_frame_indexing()
          |> fix_iasa()
          |> Map.put(:displayName, elem(parser.display_names, i))
          |> then(fn p ->
            case elem(parser.connect_codes, i) do
              "" -> p
              code -> %{p | connectCode: code}
            end
          end)

        {port, player}
      end)

    stage_extras =
      case parser.current_stage do
        @stage_fountain -> %{fod_platforms: parser.fod_platforms}
        @stage_dreamland -> %{whispy: parser.whispy}
        @stage_stadium -> %{stadium_transformation: parser.stadium_transformation}
        _ -> %{}
      end

    struct!(%{gamestate | players: players, playedOn: "dolphin"}, stage_extras)
  end

  defp fix_frame_indexing(player) do
    if FrameData.zero_indexed?(player.character, player.action) do
      %{player | action_frame: player.action_frame + 1}
    else
      player
    end
  end

  defp fix_iasa(player) do
    if player.action < @action_neutral_attack_1 or player.action > @action_dair do
      %{player | iasa: 0}
    else
      player
    end
  end

  ## Player helpers

  defp fetch_player(%GameState{players: players} = gamestate, port) do
    case Map.fetch(players, port) do
      {:ok, player} ->
        {player, gamestate}

      :error ->
        player = %PlayerState{}
        {player, %{gamestate | players: Map.put(players, port, player)}}
    end
  end

  defp put_player(gamestate, port, player),
    do: %{gamestate | players: Map.put(gamestate.players, port, player)}

  # When the event is for Nana, we edit a fresh Nana state hanging off the
  # port's player (mirroring Python, which resets nana on each event).
  defp target(_player, true), do: %PlayerState{}
  defp target(player, false), do: player

  defp merge_nana(player, true, nana), do: %{player | nana: nana}
  defp merge_nana(_player, false, updated), do: updated

  defp put_in_menu_state(parser, menu_state),
    do: %{parser | gamestate: %{parser.gamestate | menu_state: menu_state}}

  ## Binary readers — return `default` when the field is beyond the event
  ## (older SLP versions), mirroring Python's except-TypeError fallbacks.

  defp read_u8(bin, off, default) do
    case bin do
      <<_::binary-size(off), v, _::binary>> -> v
      _ -> default
    end
  end

  defp read_i8(bin, off, default) do
    case bin do
      <<_::binary-size(off), v::signed-8, _::binary>> -> v
      _ -> default
    end
  end

  defp read_u16(bin, off, default) do
    case bin do
      <<_::binary-size(off), v::big-unsigned-16, _::binary>> -> v
      _ -> default
    end
  end

  defp read_u32(bin, off, default) do
    case bin do
      <<_::binary-size(off), v::big-unsigned-32, _::binary>> -> v
      _ -> default
    end
  end

  defp read_i32(bin, off, default) do
    case bin do
      <<_::binary-size(off), v::big-signed-32, _::binary>> -> v
      _ -> default
    end
  end

  defp read_f32(bin, off, default) do
    case bin do
      <<_::binary-size(off), v::big-float-32, _::binary>> -> v
      _ -> default
    end
  end
end
