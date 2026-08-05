defmodule Melee.Stages do
  @moduledoc """
  A collection of helper data for information regarding stages.

  Port of libmelee's `stages.py`. All functions accept either a raw integer
  stage ID (the convention for game-state structs in this library) or a
  `Melee.Enums.Stage` atom.

  ## Examples

      iex> Melee.Stages.edge_position(0x18)
      71.3078536987

      iex> Melee.Stages.edge_ground_position(:yoshis_story)
      56

      iex> Melee.Stages.blastzones(:battlefield)
      {-224, 224, 200, -108.8}

      iex> Melee.Stages.top_platform_position(:final_destination)
      {nil, nil, nil}
  """

  alias Melee.Enums.Stage

  @typedoc "A raw integer stage ID or a `Melee.Enums.Stage` atom."
  @type stage :: integer() | atom()

  @typedoc "Platform position: `{height, left_edge, right_edge}` (all nil if absent)."
  @type platform :: {number() | nil, number() | nil, number() | nil}

  # Blast zone boundaries: {left x, right x, upper y, lower y}
  # Source: Magus420 —
  # https://smashboards.com/threads/official-ask-anyone-frame-things-thread.313889/page-20#post-18643652
  @blastzones %{
    battlefield: {-224, 224, 200, -108.8},
    final_destination: {-246, 246, 188, -140},
    dreamland: {-255, 255, 250, -123},
    fountain_of_dreams: {-198.75, 198.75, 202.5, -146.25},
    pokemon_stadium: {-230, 230, 180, -111},
    yoshis_story: {-175.7, 173.6, 168, -91}
  }

  # X coordinate of the stage edge, approaching from off stage
  # (your X coordinate when hanging on the edge). Left edge is the negation.
  @edge_position %{
    battlefield: 71.3078536987,
    final_destination: 88.4735488892,
    dreamland: 80.1791534424,
    fountain_of_dreams: 66.2554016113,
    pokemon_stadium: 90.657852,
    yoshis_story: 58.907848
  }

  # X coordinate of the stage edge while standing on the stage
  # (your X coordinate when teetering on the edge). Left edge is the negation.
  @edge_ground_position %{
    battlefield: 68.4000015259,
    final_destination: 85.5656967163,
    dreamland: 77.2713012695,
    fountain_of_dreams: 63.3475494385,
    pokemon_stadium: 87.75,
    yoshis_story: 56
  }

  @top_platform %{
    battlefield: {54.40010070800781, -18.80000114440918, 18.80000114440918},
    dreamland: {51.42539978027344, -19.01810073852539, 19.017099380493164},
    fountain_of_dreams: {42.750099182128906, -14.25, 14.25},
    yoshis_story: {42.000099182128906, -15.75, 15.75}
  }

  # Fountain of Dreams side platforms move; positions are TODO upstream too.
  @left_platform %{
    pokemon_stadium: {25.000099182128906, -55, -25},
    battlefield: {27.20009994506836, -57.60000228881836, -20},
    dreamland: {30.14219856262207, -61.39289855957031, -31.725400924682617},
    yoshis_story: {23.450098037719727, -59.5, -28.0}
  }

  @right_platform %{
    pokemon_stadium: {25.000099182128906, 25, 55},
    battlefield: {27.20009994506836, 20, 57.60000228881836},
    dreamland: {30.242599487304688, 31.70359992980957, 63.074501037597656},
    yoshis_story: {23.450098037719727, 28.0, 59.5}
  }

  @randall_corner_positions %{
    416 => {-33.184478759765625, 89.75263977050781},
    417 => {-33.04470443725586, 90.07878112792969},
    418 => {-32.904930114746094, 90.40492248535156},
    419 => {-32.76515197753906, 90.73107147216797},
    420 => {-32.49260711669922, 90.92455291748047},
    421 => {-32.16635513305664, 91.06437683105469},
    422 => {-31.840103149414062, 91.20419311523438},
    423 => {-31.513851165771484, 91.3440170288086},
    469 => {-15.1948881149292, 91.3371353149414},
    470 => {-14.868742942810059, 91.1973648071289},
    471 => {-14.542601585388184, 91.05758666992188},
    472 => {-14.216456413269043, 90.91781616210938},
    473 => {-13.967143058776855, 90.71036529541016},
    474 => {-13.869664192199707, 90.36917877197266},
    475 => {-13.772183418273926, 90.02799224853516},
    476 => {-13.674698829650879, 89.68680572509766},
    1069 => {-31.590042114257812, -103.554931640625},
    1070 => {-31.907413482666016, -103.39625549316406},
    1071 => {-32.22478485107422, -103.23756408691406},
    1072 => {-32.54215621948242, -103.07887268066406},
    1073 => {-32.7216796875, -102.77439880371094},
    1074 => {-32.89775085449219, -102.46626281738281},
    1075 => {-33.07382583618164, -102.15814208984375},
    1016 => {-13.679760932922363, -101.919677734375},
    1017 => {-13.819535255432129, -102.24581909179688},
    1018 => {-13.959305763244629, -102.57196044921875},
    1019 => {-14.099089622497559, -102.89810180664062},
    1020 => {-14.320136070251465, -103.14761352539062},
    1021 => {-14.6375150680542, -103.30630493164062},
    1022 => {-14.954894065856934, -103.46499633789062}
  }

  @randall_interval 1200
  @randall_width 11.9

  @doc "Returns the Randall movement cycle length in frames (1200)."
  @spec randall_interval() :: pos_integer()
  def randall_interval, do: @randall_interval

  @doc """
  Returns the blast zone boundaries `{left_x, right_x, top_y, bottom_y}`
  for a stage, or `nil` for stages with no data.
  """
  @spec blastzones(stage()) :: {number(), number(), number(), number()} | nil
  def blastzones(stage), do: Map.get(@blastzones, key(stage))

  @doc """
  Returns the X coordinate of the stage edge, approaching from off stage
  (your X when hanging on the edge), or `nil` for stages with no data.

  The left edge is the same value, negated.
  """
  @spec edge_position(stage()) :: number() | nil
  def edge_position(stage), do: Map.get(@edge_position, key(stage))

  @doc """
  Returns the X coordinate of the stage edge while standing on the stage
  (your X when teetering on the edge), or `nil` for stages with no data.

  The left edge is the same value, negated.
  """
  @spec edge_ground_position(stage()) :: number() | nil
  def edge_ground_position(stage), do: Map.get(@edge_ground_position, key(stage))

  @doc """
  Returns the position of the top platform as `{height, left_edge, right_edge}`,
  or `{nil, nil, nil}` if the stage has no top platform.
  """
  @spec top_platform_position(stage()) :: platform()
  def top_platform_position(stage), do: Map.get(@top_platform, key(stage), {nil, nil, nil})

  @doc """
  Returns the position of the specified side platform as
  `{height, left_edge, right_edge}` — the right platform when
  `right_platform?` is true, otherwise the left.
  """
  @spec side_platform_position(boolean(), stage()) :: platform()
  def side_platform_position(right_platform?, stage) do
    if right_platform? do
      right_platform_position(stage)
    else
      left_platform_position(stage)
    end
  end

  @doc """
  Returns the position of the left platform as `{height, left_edge, right_edge}`,
  or `{nil, nil, nil}` if absent (including Fountain of Dreams, whose moving
  side platforms are unmapped upstream).
  """
  @spec left_platform_position(stage()) :: platform()
  def left_platform_position(stage), do: Map.get(@left_platform, key(stage), {nil, nil, nil})

  @doc """
  Returns the position of the right platform as `{height, left_edge, right_edge}`,
  or `{nil, nil, nil}` if absent (including Fountain of Dreams, whose moving
  side platforms are unmapped upstream).
  """
  @spec right_platform_position(stage()) :: platform()
  def right_platform_position(stage), do: Map.get(@right_platform, key(stage), {nil, nil, nil})

  @doc """
  Returns the current position of Randall as `{height, x_left, x_right}`
  for a given frame of the Yoshi's Story cycle.

  The values are not EXACT — Randall's location is extrapolated rather than
  read from memory — but they are at most off by about 0.001 in practice.
  """
  @spec randall_position(integer()) :: {float(), float(), float()}
  def randall_position(frame) when is_integer(frame) do
    frame_count = Integer.mod(frame + @randall_interval, @randall_interval)

    cond do
      # Top section
      476 < frame_count and frame_count < 1016 ->
        start = 101.235443115234
        speed = -0.35484
        frames_in = frame_count - 477
        {-13.64989, start - @randall_width + speed * frames_in, start + speed * frames_in}

      # Left section
      1022 < frame_count and frame_count < 1069 ->
        start = -15.2778692245483
        speed = -0.354839325
        frames_in = frame_count - 1023
        {start + speed * frames_in, -103.6, -91.7}

      # Bottom section
      frame_count > 1075 or frame_count < 416 ->
        start = -101.850006103516
        speed = 0.35484
        frames_in = if frame_count < 416, do: 125 + frame_count, else: frame_count - 1076
        {-33.2489, start + speed * frames_in, start + @randall_width + speed * frames_in}

      # Right section
      423 < frame_count and frame_count < 469 ->
        start = -31.160232543945312
        speed = 0.354839325
        frames_in = frame_count - 424
        {start + speed * frames_in, 91.35, 103.25}

      # Rounded corners of Randall's path (hardcoded, as upstream)
      true ->
        {y, x} = Map.fetch!(@randall_corner_positions, frame_count)
        {y, x, x + @randall_width}
    end
  end

  # Normalizes a stage argument (raw integer ID or atom) to a stage atom.
  defp key(stage) when is_integer(stage), do: Stage.from_id(stage)
  defp key(stage) when is_atom(stage), do: stage
end
