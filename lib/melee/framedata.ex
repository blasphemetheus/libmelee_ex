defmodule Melee.FrameData do
  @moduledoc """
  Static per-character frame data compiled from libmelee's CSV tables,
  plus the query API ported from libmelee's `framedata.py`.

  Three tables are loaded at compile time from `priv/`:

    * `actiondata.csv` — which (character, action) pairs report their
      animation frame zero-indexed in Slippi. libmelee (and this port)
      normalizes those to 1-indexed in `Melee.PlayerState.action_frame`.
    * `characterdata.csv` — physics constants per character (gravity,
      friction, air speed, ...).
    * `framedata.csv` — per (character, action, frame) hitbox and
      locomotion data used by the attack/roll query functions.

  Characters and actions are raw integer IDs (Fox = `0x01` internal).
  Every query also accepts atoms, converted via
  `Melee.Enums.Character.to_id/1` / `Melee.Enums.Action.to_id/1`.

  As in libmelee, the data is written to be useful to bots and behave in
  a sane way, not necessarily be binary-compatible with in-game values.
  """

  alias Melee.Enums.Action
  alias Melee.Enums.Character
  alias Melee.PlayerState
  alias Melee.Stages

  @external_resource actiondata_path = Path.join(__DIR__, "../../priv/actiondata.csv")
  @external_resource characterdata_path = Path.join(__DIR__, "../../priv/characterdata.csv")
  @external_resource framedata_path = Path.join(__DIR__, "../../priv/framedata.csv")

  parse_csv = fn path ->
    [header | rows] =
      path
      |> File.read!()
      |> String.split(["\r\n", "\n"], trim: true)

    split = fn line ->
      line
      |> String.split(",")
      |> Enum.map(&String.trim(&1, "\""))
    end

    keys = split.(header)
    Enum.map(rows, fn row -> Enum.zip(keys, split.(row)) |> Map.new() end)
  end

  @zero_indices actiondata_path
                |> parse_csv.()
                |> Enum.filter(&(&1["zeroindex"] == "True"))
                |> Enum.group_by(
                  &String.to_integer(&1["character"]),
                  &String.to_integer(&1["action"])
                )
                |> Map.new(fn {char, actions} -> {char, MapSet.new(actions)} end)

  @characterdata characterdata_path
                 |> parse_csv.()
                 |> Map.new(fn row ->
                   {name, row} = Map.pop(row, "Character")
                   index = String.to_integer(row["CharacterIndex"])

                   numeric =
                     Map.new(row, fn {k, v} ->
                       case Float.parse(v) do
                         {f, ""} -> {k, f}
                         _ -> {k, v}
                       end
                     end)

                   {index, Map.put(numeric, "Character", name)}
                 end)

  # framedata.csv is large (~65k rows); parse it leanly (no per-row string
  # maps) into %{{character, action} => %{frame => frame_tuple}} where each
  # frame_tuple is:
  #   {h1_status, h1_size, h1_x, h1_y,
  #    h2_status, h2_size, h2_x, h2_y,
  #    h3_status, h3_size, h3_x, h3_y,
  #    h4_status, h4_size, h4_x, h4_y,
  #    locomotion_x, locomotion_y, iasa, facing_changed, projectile}
  parse_bool = fn
    "True" -> true
    _ -> false
  end

  parse_float = fn s ->
    {f, ""} = Float.parse(s)
    f
  end

  # The full 65k-row nested map is far too large to embed as a module literal
  # (it stalls the BEAM compiler for minutes), so it is embedded as a
  # compressed external term (< 1 MB) and decoded lazily into
  # :persistent_term on first use.
  @framedata_binary framedata_path
                    |> File.read!()
                    |> String.split(["\r\n", "\n"], trim: true)
                    |> tl()
                    |> Enum.reduce(%{}, fn line, acc ->
                      [char, action, frame | rest] =
                        line |> String.split(",") |> Enum.map(&String.trim(&1, "\""))

                      [
                        h1s,
                        h1sz,
                        h1x,
                        h1y,
                        h2s,
                        h2sz,
                        h2x,
                        h2y,
                        h3s,
                        h3sz,
                        h3x,
                        h3y,
                        h4s,
                        h4sz,
                        h4x,
                        h4y,
                        locox,
                        locoy,
                        iasa,
                        fc,
                        proj
                      ] = rest

                      tuple =
                        {parse_bool.(h1s), parse_float.(h1sz), parse_float.(h1x),
                         parse_float.(h1y), parse_bool.(h2s), parse_float.(h2sz),
                         parse_float.(h2x), parse_float.(h2y), parse_bool.(h3s),
                         parse_float.(h3sz), parse_float.(h3x), parse_float.(h3y),
                         parse_bool.(h4s), parse_float.(h4sz), parse_float.(h4x),
                         parse_float.(h4y), parse_float.(locox), parse_float.(locoy),
                         parse_bool.(iasa), parse_bool.(fc), parse_bool.(proj)}

                      key = {String.to_integer(char), String.to_integer(action)}

                      Map.update(
                        acc,
                        key,
                        %{String.to_integer(frame) => tuple},
                        &Map.put(&1, String.to_integer(frame), tuple)
                      )
                    end)
                    |> :erlang.term_to_binary([:compressed])

  @framedata_key {__MODULE__, :framedata}

  # Returns the %{{character, action} => %{frame => frame_tuple}} table,
  # decoding it into :persistent_term on first access.
  defp framedata do
    :persistent_term.get(@framedata_key)
  rescue
    ArgumentError ->
      table = :erlang.binary_to_term(@framedata_binary)
      :persistent_term.put(@framedata_key, table)
      table
  end

  # Tuple indices for the per-frame data.
  @idx_locomotion_x 16
  @idx_locomotion_y 17
  @idx_iasa 18
  @idx_facing_changed 19
  @idx_projectile 20

  @type character :: integer() | atom()
  @type action :: integer() | atom()
  @type frame_data :: %{
          hitbox_1_status: boolean(),
          hitbox_1_size: float(),
          hitbox_1_x: float(),
          hitbox_1_y: float(),
          hitbox_2_status: boolean(),
          hitbox_2_size: float(),
          hitbox_2_x: float(),
          hitbox_2_y: float(),
          hitbox_3_status: boolean(),
          hitbox_3_size: float(),
          hitbox_3_x: float(),
          hitbox_3_y: float(),
          hitbox_4_status: boolean(),
          hitbox_4_size: float(),
          hitbox_4_x: float(),
          hitbox_4_y: float(),
          locomotion_x: float(),
          locomotion_y: float(),
          iasa: boolean(),
          facing_changed: boolean(),
          projectile: boolean()
        }

  @doc """
  Does the given (character, action) pair report zero-indexed animation
  frames in the Slippi stream?

  ## Examples

      iex> Melee.FrameData.zero_indexed?(22, 323)
      true

      iex> Melee.FrameData.zero_indexed?(22, 322)
      false
  """
  @spec zero_indexed?(character(), action()) :: boolean()
  def zero_indexed?(character, action) do
    case Map.fetch(@zero_indices, char_id(character)) do
      {:ok, actions} -> MapSet.member?(actions, action_id(action))
      :error -> false
    end
  end

  @doc "Physics constants for a character (by in-game character index), or nil."
  @spec character_data(character()) :: map() | nil
  def character_data(character), do: Map.get(@characterdata, char_id(character))

  # ---------------------------------------------------------------------------
  # Action classification
  # ---------------------------------------------------------------------------

  @grab_actions [Action.to_id(:grab), Action.to_id(:grab_running)]
  @falcon_ganon_grabs [Action.to_id(:sword_dance_3_mid), Action.to_id(:sword_dance_3_low)]
  @bowser_grabs [Action.to_id(:neutral_b_attacking_air), Action.to_id(:sword_dance_3_mid)]
  @yoshi_grabs [Action.to_id(:neutral_b_charging_air), Action.to_id(:sword_dance_2_mid)]
  @mewtwo_grabs [Action.to_id(:sword_dance_2_mid), Action.to_id(:sword_dance_3_high)]

  @doc """
  For the given character, is the supplied action a grab?

  This includes command grabs, such as Bowser's claw. Not just Z-grabs.

  ## Examples

      iex> Melee.FrameData.grab?(:fox, :grab)
      true

      iex> Melee.FrameData.grab?(:bowser, :neutral_b_attacking_air)
      true

      iex> Melee.FrameData.grab?(:fox, :nair)
      false
  """
  @spec grab?(character(), action()) :: boolean()
  def grab?(character, action) do
    character = char_id(character)
    action = action_id(action)

    cond do
      action in @grab_actions ->
        true

      character in [Character.to_id(:cptfalcon), Character.to_id(:ganondorf)] and
          action in @falcon_ganon_grabs ->
        true

      character == Character.to_id(:bowser) and action in @bowser_grabs ->
        true

      character == Character.to_id(:yoshi) and action in @yoshi_grabs ->
        true

      character == Character.to_id(:mewtwo) and action in @mewtwo_grabs ->
        true

      true ->
        false
    end
  end

  @roll_actions Enum.map(
                  [
                    :spotdodge,
                    :roll_forward,
                    :roll_backward,
                    :neutral_tech,
                    :forward_tech,
                    :backward_tech,
                    :ground_getup,
                    :tech_miss_up,
                    :tech_miss_down,
                    :edge_getup_slow,
                    :edge_getup_quick,
                    :edge_roll_slow,
                    :edge_roll_quick,
                    :ground_roll_forward_up,
                    :ground_roll_backward_up,
                    :ground_roll_forward_down,
                    :ground_roll_backward_down,
                    :shield_break_fly,
                    :shield_break_fall,
                    :shield_break_down_u,
                    :shield_break_down_d,
                    :shield_break_stand_u,
                    :shield_break_stand_d,
                    :taunt_right,
                    :taunt_left,
                    :shield_break_teeter
                  ],
                  &Action.to_id/1
                )

  @doc """
  For a given character, is the supplied action a roll?

  libmelee has a liberal definition of "roll". A roll is essentially a
  move that (1) has no hitbox and (2) is inactionable. Spot dodge and
  (most) taunts, for example, are considered rolls by this function.

  ## Examples

      iex> Melee.FrameData.roll?(:marth, :marth_counter)
      true

      iex> Melee.FrameData.roll?(:fox, :roll_forward)
      true

      iex> Melee.FrameData.roll?(:fox, :nair)
      false
  """
  @spec roll?(character(), action()) :: boolean()
  def roll?(character, action) do
    character = char_id(character)
    action = action_id(action)

    (character == Character.to_id(:marth) and
       action in [Action.to_id(:marth_counter), Action.to_id(:marth_counter_falling)]) or
      action in @roll_actions
  end

  # This libmelee version references Action.UNKNOWN_ANIMATION here, an enum
  # member that no longer exists in its own enums (calling is_bmove in Python
  # raises AttributeError). We use its historical value, 0xFFFF.
  @unknown_animation 0xFFFF
  @laser_gun_pull Action.to_id(:laser_gun_pull)
  @peach_non_bmoves [
    Action.to_id(:laser_gun_pull),
    Action.to_id(:neutral_b_charging),
    Action.to_id(:neutral_b_attacking)
  ]
  @peach_smashes [
    Action.to_id(:sword_dance_2_mid),
    Action.to_id(:sword_dance_1),
    Action.to_id(:sword_dance_2_high)
  ]

  @doc """
  For a given character, is the supplied action a "B-move"?

  B-moves tend to be weird, so it's useful to know if this is a thing
  that warrants a special case.

  ## Examples

      iex> Melee.FrameData.bmove?(:fox, :down_b_ground)
      true

      iex> Melee.FrameData.bmove?(:peach, :neutral_b_charging)
      false

      iex> Melee.FrameData.bmove?(:fox, :walk_slow)
      false
  """
  @spec bmove?(character(), action()) :: boolean()
  def bmove?(character, action) do
    character = char_id(character)
    action = action_id(action)

    cond do
      # If we're missing it, don't call it a B move
      action == @unknown_animation ->
        false

      # Don't consider Peach float to be a B move (but the rest of her float
      # aerials ARE); Peach smashes also shouldn't be B moves.
      character == Character.to_id(:peach) and
          (action in @peach_non_bmoves or action in @peach_smashes) ->
        false

      @laser_gun_pull <= action ->
        true

      true ->
        false
    end
  end

  @doc """
  For a given character, is the supplied action an attack?

  It is an attack if it has a hitbox at any point in the action — not
  necessarily right now.

  ## Examples

      iex> Melee.FrameData.attack?(:fox, :nair)
      true

      iex> Melee.FrameData.attack?(:fox, :walk_slow)
      false
  """
  @spec attack?(character(), action()) :: boolean()
  def attack?(character, action) do
    character
    |> frames_for(action)
    |> Enum.any?(fn {_frame, tuple} -> hitbox_frame?(tuple) end)
  end

  @shield_actions Enum.map(
                    [:shield, :shield_start, :shield_reflect, :shield_stun, :shield_release],
                    &Action.to_id/1
                  )

  @doc """
  Is the given action a shielding action?

  ## Examples

      iex> Melee.FrameData.shield?(:shield)
      true

      iex> Melee.FrameData.shield?(:nair)
      false
  """
  @spec shield?(action()) :: boolean()
  def shield?(action), do: action_id(action) in @shield_actions

  @doc """
  Returns the number of double-jumps the given character has.

  This means in general, not according to the current gamestate.

  ## Examples

      iex> Melee.FrameData.max_jumps(:jigglypuff)
      5

      iex> Melee.FrameData.max_jumps(:fox)
      1
  """
  @spec max_jumps(character()) :: integer()
  def max_jumps(character) do
    character = char_id(character)

    if character in [Character.to_id(:jigglypuff), Character.to_id(:kirby)] do
      5
    else
      1
    end
  end

  @doc """
  For the given character/action/frame, returns the current attack state:
  `:windup`, `:attacking`, `:cooldown`, or `:not_attacking`.

  ## Examples

      iex> Melee.FrameData.attack_state(:marth, :fsmash_mid, 1)
      :windup

      iex> Melee.FrameData.attack_state(:marth, :fsmash_mid, 12)
      :attacking

      iex> Melee.FrameData.attack_state(:marth, :fsmash_mid, 50)
      :cooldown

      iex> Melee.FrameData.attack_state(:fox, :walk_slow, 3)
      :not_attacking
  """
  @spec attack_state(character(), action(), integer()) ::
          :windup | :attacking | :cooldown | :not_attacking
  def attack_state(character, action, action_frame) do
    cond do
      not attack?(character, action) -> :not_attacking
      action_frame < first_hitbox_frame(character, action) -> :windup
      action_frame > last_hitbox_frame(character, action) -> :cooldown
      true -> :attacking
    end
  end

  # ---------------------------------------------------------------------------
  # Hitbox frame queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns the raw frame data for the given character/action/frame as a map,
  or nil if there is no entry.
  """
  @spec get_frame(character(), action(), integer()) :: frame_data() | nil
  def get_frame(character, action, action_frame) do
    case Map.get(frames_for(character, action), action_frame) do
      nil -> nil
      tuple -> frame_tuple_to_map(tuple)
    end
  end

  @doc """
  Returns the first frame that a hitbox appears for a given action.
  Returns -1 if there are no hitboxes (not an attack action).

  ## Examples

      iex> Melee.FrameData.first_hitbox_frame(:fox, :down_b_ground_start)
      1

      iex> Melee.FrameData.first_hitbox_frame(0x01, 0x41)
      4

      iex> Melee.FrameData.first_hitbox_frame(:fox, :walk_slow)
      -1
  """
  @spec first_hitbox_frame(character(), action()) :: integer()
  def first_hitbox_frame(character, action) do
    character
    |> hitbox_frames(action)
    |> Enum.min(fn -> -1 end)
  end

  @doc """
  Returns the last frame that a hitbox appears for a given action.
  Returns -1 if there are no hitboxes (not an attack action).

  ## Examples

      iex> Melee.FrameData.last_hitbox_frame(:fox, :nair)
      31

      iex> Melee.FrameData.last_hitbox_frame(:marth, :fsmash_mid)
      13
  """
  @spec last_hitbox_frame(character(), action()) :: integer()
  def last_hitbox_frame(character, action) do
    character
    |> hitbox_frames(action)
    |> Enum.max(fn -> -1 end)
  end

  @doc """
  Returns the number of hitboxes an attack has.

  By this we mean: is it a multihit attack (Peach's down B?) or a
  single-hit attack (Marth's fsmash?).

  ## Examples

      iex> Melee.FrameData.hitbox_count(:fox, :dair)
      7

      iex> Melee.FrameData.hitbox_count(:marth, :fsmash_mid)
      1
  """
  @spec hitbox_count(character(), action()) :: integer()
  def hitbox_count(character, action) do
    char = char_id(character)
    act = action_id(action)

    cond do
      # This math doesn't work for Samus's UP_B because the hitboxes are contiguous
      char == Character.to_id(:samus) and
          act in [Action.to_id(:sword_dance_3_mid), Action.to_id(:sword_dance_3_low)] ->
        7

      char == Character.to_id(:ylink) and act == Action.to_id(:sword_dance_4_mid) ->
        10

      true ->
        case hitbox_frames(char, act) do
          [] ->
            0

          hitboxes ->
            set = MapSet.new(hitboxes)

            # Every time we go from NOT having a hitbox to having one, up the count
            1..Enum.max(hitboxes)
            |> Enum.reduce({false, 0}, fn i, {had, count} ->
              has = MapSet.member?(set, i)
              {has, if(has and not had, do: count + 1, else: count)}
            end)
            |> elem(1)
        end
    end
  end

  @doc """
  Returns the first frame of an attack in which the character is
  interruptible (actionable). Returns -1 if not an attack.

  ## Examples

      iex> Melee.FrameData.iasa(:marth, :fsmash_mid)
      48

      iex> Melee.FrameData.iasa(:fox, :walk_slow)
      -1
  """
  @spec iasa(character(), action()) :: integer()
  def iasa(character, action) do
    if attack?(character, action) do
      frames = frames_for(character, action)

      iasa_frames =
        for {frame, tuple} <- frames, elem(tuple, @idx_iasa), do: frame

      case iasa_frames do
        [] -> frames |> Map.keys() |> Enum.max()
        _ -> Enum.min(iasa_frames)
      end
    else
      -1
    end
  end

  @doc """
  Returns the count of total frames in the given action, or -1 if the
  action has no frame data.

  ## Examples

      iex> Melee.FrameData.frame_count(:fox, :nair)
      49

      iex> Melee.FrameData.frame_count(:fox, :walk_slow)
      -1
  """
  @spec frame_count(character(), action()) :: integer()
  def frame_count(character, action) do
    character
    |> frames_for(action)
    |> Map.keys()
    |> Enum.max(fn -> -1 end)
  end

  @doc """
  Returns the last frame of the roll, or -1 if the action is not a roll.

  ## Examples

      iex> Melee.FrameData.last_roll_frame(:fox, :roll_forward)
      31

      iex> Melee.FrameData.last_roll_frame(:fox, :nair)
      -1
  """
  @spec last_roll_frame(character(), action()) :: integer()
  def last_roll_frame(character, action) do
    if roll?(character, action) do
      character
      |> frames_for(action)
      |> Map.keys()
      |> Enum.max(fn -> -1 end)
    else
      -1
    end
  end

  # ---------------------------------------------------------------------------
  # Range queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns the maximum remaining range of the given attack, in the forward
  direction (relative to how the character starts facing).

  "Remaining" means hitboxes that we've already passed aren't considered.
  """
  @spec range_forward(character(), action(), integer()) :: number()
  def range_forward(character, action, action_frame) do
    remaining_range(character, action, action_frame, fn tuple, acc ->
      acc
      |> max_if_active(tuple, 0)
      |> max_if_active(tuple, 4)
      |> max_if_active(tuple, 8)
      |> max_if_active(tuple, 12)
    end)
  end

  @doc """
  Returns the maximum remaining range of the given attack, in the backwards
  direction (relative to how the character starts facing).

  "Remaining" means hitboxes that we've already passed aren't considered.
  """
  @spec range_backward(character(), action(), integer()) :: number()
  def range_backward(character, action, action_frame) do
    character
    |> remaining_range(action, action_frame, fn tuple, acc ->
      acc
      |> min_if_active(tuple, 0)
      |> min_if_active(tuple, 4)
      |> min_if_active(tuple, 8)
      |> min_if_active(tuple, 12)
    end)
    |> abs()
  end

  defp remaining_range(character, action, action_frame, fold_fn) do
    frames = frames_for(character, action)
    lastframe = last_hitbox_frame(character, action)

    if action_frame + 1 > lastframe do
      0
    else
      Enum.reduce((action_frame + 1)..lastframe, 0, fn i, acc ->
        case Map.get(frames, i) do
          nil -> acc
          tuple -> fold_fn.(tuple, acc)
        end
      end)
    end
  end

  # Hitbox slot base indices: status at base, size at base+1, x at base+2.
  defp max_if_active(acc, tuple, base) do
    if elem(tuple, base) do
      max(elem(tuple, base + 1) + elem(tuple, base + 2), acc)
    else
      acc
    end
  end

  defp min_if_active(acc, tuple, base) do
    if elem(tuple, base) do
      min(-elem(tuple, base + 1) + elem(tuple, base + 2), acc)
    else
      acc
    end
  end

  @doc """
  Calculates if an attack is in range of a given defender.

  Returns the frame of the attacker's action on which the attack will hit
  the defender, or 0 if it won't hit.

  This considers the defending character to have a single hurtbox, centered
  at the x,y coordinates of the player (adjusted up a little to be centered).
  """
  @spec in_range(PlayerState.t(), PlayerState.t(), Stages.stage()) :: integer()
  def in_range(%PlayerState{} = attacker, %PlayerState{} = defender, stage) do
    frames = frames_for(attacker.character, attacker.action)
    lastframe = last_hitbox_frame(attacker.character, attacker.action)

    # Adjust the defender's hurtbox up a little, to be more centered.
    # The game keeps y coordinates based on the bottom of a character, not
    # their center. So we need to move up by one radius of the character's size.
    defender_size = character_data(defender.character)["size"] / 1
    defender_y = defender.position.y + defender_size

    chardata = character_data(attacker.character)
    friction = chardata["Friction"]
    gravity = chardata["Gravity"]
    termvelocity = chardata["TerminalVelocity"]

    speed_x =
      if attacker.on_ground,
        do: attacker.speed_ground_x_self,
        else: attacker.speed_air_x_self

    init = %{
      x: attacker.position.x / 1,
      y: attacker.position.y / 1,
      speed_x: speed_x / 1,
      speed_y: attacker.speed_y_self / 1,
      on_ground: attacker.on_ground
    }

    if attacker.action_frame + 1 > lastframe do
      0
    else
      (attacker.action_frame + 1)..lastframe
      |> Enum.reduce_while(init, fn i, st ->
        case Map.get(frames, i) do
          nil ->
            {:cont, st}

          tuple ->
            st = in_range_step(st, tuple, friction, gravity, termvelocity, stage)

            if hitbox_active?(tuple) and
                 in_range_hit?(
                   st,
                   tuple,
                   attacker.facing,
                   defender.position.x,
                   defender_y,
                   defender_size
                 ) do
              {:halt, {:hit, i}}
            else
              {:cont, st}
            end
        end
      end)
      |> case do
        {:hit, i} -> i
        _ -> 0
      end
    end
  end

  # Advance the attacker's projected position by one frame.
  defp in_range_step(st, tuple, friction, gravity, termvelocity, stage) do
    locomotion_x = elem(tuple, @idx_locomotion_x)
    locomotion_y = elem(tuple, @idx_locomotion_y)

    cond do
      locomotion_x != 0 or locomotion_y != 0 ->
        %{st | x: st.x + locomotion_x, y: st.y + locomotion_y}

      st.on_ground ->
        # Slow down the speed by the character's friction, then apply it
        speed_x =
          if st.speed_x > 0,
            do: max(0, st.speed_x - friction),
            else: min(0, st.speed_x + friction)

        %{st | speed_y: 0, speed_x: speed_x, x: st.x + speed_x}

      true ->
        # In the air: decelerate towards the stage
        speed_y = max(-termvelocity, st.speed_y - gravity)
        y = st.y + speed_y
        edge = Stages.edge_ground_position(stage)

        {y, speed_y, on_ground} =
          if y <= 0 and is_number(edge) and abs(st.x) < edge do
            {0, 0, true}
          else
            {y, speed_y, st.on_ground}
          end

        %{st | speed_y: speed_y, y: y, x: st.x + st.speed_x, on_ground: on_ground}
    end
  end

  defp in_range_hit?(st, tuple, facing, defender_x, defender_y, defender_size) do
    Enum.any?([0, 4, 8, 12], fn base ->
      hitbox_x = if facing, do: elem(tuple, base + 2), else: -elem(tuple, base + 2)
      hitbox_x = hitbox_x + st.x
      hitbox_y = elem(tuple, base + 3) + st.y

      distance =
        :math.sqrt(:math.pow(hitbox_x - defender_x, 2) + :math.pow(hitbox_y - defender_y, 2))

      distance < defender_size + elem(tuple, base + 1)
    end)
  end

  # ---------------------------------------------------------------------------
  # Jump physics
  # ---------------------------------------------------------------------------

  @peach_dj_height 33.218964577

  @doc """
  Returns the height the character's double jump will take them.
  If the character is in a jump already, returns how high that one goes.
  """
  @spec dj_height(PlayerState.t()) :: number()
  def dj_height(%PlayerState{} = character_state) do
    # Peach's DJ doesn't follow normal physics rules. Hardcoded it.
    if character_state.character == Character.to_id(:peach) do
      cond do
        # She can't get height if not in the jump action
        character_state.action != Action.to_id(:jumping_arial_forward) and
            character_state.jumps_left == 0 ->
          0

        character_state.action != Action.to_id(:jumping_arial_forward) ->
          @peach_dj_height

        true ->
          # This isn't exact. But it's close.
          @peach_dj_height * (1 - character_state.action_frame / 60)
      end
    else
      gravity = character_data(character_state.character)["Gravity"]
      initdjspeed = init_dj_speed(character_state, gravity)
      dj_distance(initdjspeed, gravity, 0)
    end
  end

  @doc """
  Returns the number of frames it takes for the character to reach the apex
  of their double jump. If they haven't used it yet, calculates as if they
  jumped right now.
  """
  @spec frames_until_dj_apex(PlayerState.t()) :: integer()
  def frames_until_dj_apex(%PlayerState{} = character_state) do
    # Peach's DJ doesn't follow normal physics rules.
    # She can float-cancel, so she can be falling at any time during the jump.
    if character_state.character == Character.to_id(:peach) do
      1
    else
      gravity = character_data(character_state.character)["Gravity"]
      initdjspeed = init_dj_speed(character_state, gravity)
      dj_frames(initdjspeed, gravity, 0)
    end
  end

  defp init_dj_speed(character_state, gravity) do
    initdjspeed =
      if character_state.jumps_left == 0 do
        character_state.speed_y_self - gravity
      else
        character_data(character_state.character)["InitDJSpeed"]
      end

    if character_state.character == Character.to_id(:jigglypuff) do
      case character_state.jumps_left do
        n when n >= 5 -> 1.586
        4 -> 1.526
        3 -> 1.406
        2 -> 1.296
        _ -> 1.186
      end
    else
      initdjspeed
    end
  end

  defp dj_distance(speed, gravity, distance) when speed > 0,
    do: dj_distance(speed - gravity, gravity, distance + speed)

  defp dj_distance(_speed, _gravity, distance), do: distance

  defp dj_frames(speed, gravity, frames) when speed > 0,
    do: dj_frames(speed - gravity, gravity, frames + 1)

  defp dj_frames(_speed, _gravity, frames), do: frames

  # ---------------------------------------------------------------------------
  # Rolls and slides
  # ---------------------------------------------------------------------------

  @backroll_actions Enum.map(
                      [
                        :roll_backward,
                        :ground_roll_backward_up,
                        :ground_roll_backward_down,
                        :backward_tech
                      ],
                      &Action.to_id/1
                    )
  @tech_miss_actions Enum.map([:tech_miss_up, :tech_miss_down], &Action.to_id/1)

  @doc """
  Returns the x coordinate that the current roll will end in.

  If there is no frame data for the character's current action frame,
  returns the current x position (matching the Python KeyError path).
  """
  @spec roll_end_position(PlayerState.t(), Stages.stage()) :: number()
  def roll_end_position(%PlayerState{} = character_state, stage) do
    frames = frames_for(character_state.character, character_state.action)

    case Map.get(frames, character_state.action_frame) do
      nil ->
        # Assume this animation doesn't go anywhere
        character_state.position.x

      current_tuple ->
        # TODO(libmelee): take current momentum into account.
        # Sum locomotion over the frames that haven't happened yet, in frame order.
        distance =
          frames
          |> Enum.sort_by(fn {frame, _} -> frame end)
          |> Enum.reduce(0, fn {frame, tuple}, acc ->
            if frame > character_state.action_frame do
              acc + elem(tuple, @idx_locomotion_x)
            else
              acc
            end
          end)

        # Derive the direction we're supposed to be moving by xor'ing together:
        #   1) current facing, 2) facing changed in the frame data, 3) is backwards roll
        facing_changed = elem(current_tuple, @idx_facing_changed)
        backroll = character_state.action in @backroll_actions

        distance =
          if xor(xor(character_state.facing, facing_changed), backroll),
            do: distance,
            else: -distance

        position = character_state.position.x + distance

        if character_state.action in @tech_miss_actions do
          position
        else
          clamp_to_platform(position, character_state.position, stage)
        end
    end
  end

  defp xor(a, b), do: a != b

  # Adjust the position to account for the fact that we can't roll off the platform
  defp clamp_to_platform(position, %{x: x, y: y}, stage) do
    {side_h, side_l, side_r} = Stages.side_platform_position(x > 0, stage)
    {top_h, top_l, top_r} = Stages.top_platform_position(stage)
    edge = Stages.edge_ground_position(stage)

    cond do
      y < 5 and is_number(edge) ->
        position |> min(edge) |> max(-edge)

      side_h != nil and abs(y - side_h) < 5 ->
        position |> min(side_r) |> max(side_l)

      top_h != nil and abs(y - top_h) < 5 ->
        position |> min(top_r) |> max(top_l)

      true ->
        position
    end
  end

  @tech_miss_up Action.to_id(:tech_miss_up)

  @doc """
  How far a character will slide in the given number of frames, starting
  at `initspeed`.
  """
  @spec slide_distance(PlayerState.t(), number(), integer()) :: number()
  def slide_distance(%PlayerState{} = character_state, initspeed, frames) do
    chardata = character_data(character_state.character)
    normalfriction = chardata["Friction"]
    walkspeed = chardata["MaxWalkSpeed"]
    absspeed = abs(initspeed)

    total =
      if frames < 1 do
        0
      else
        0..(frames - 1)
        |> Enum.reduce_while({absspeed, 0, normalfriction, 1}, fn i,
                                                                  {absspeed, total, friction,
                                                                   multiplier} ->
          # Special case for these two damn animations, for some reason. Thanks Melee.
          {friction, multiplier} =
            cond do
              character_state.action == @tech_miss_up ->
                if character_state.action_frame + i < 18,
                  do: {0.051, 1},
                  else: {normalfriction, multiplier}

              # If we're sliding faster than the character's walk speed,
              # the slowdown is doubled
              absspeed > walkspeed ->
                {friction, 2}

              true ->
                {friction, 1}
            end

          absspeed = absspeed - friction * multiplier

          if absspeed < 0 do
            {:halt, {absspeed, total, friction, multiplier}}
          else
            {:cont, {absspeed, total + absspeed, friction, multiplier}}
          end
        end)
        |> elem(1)
      end

    if initspeed < 0, do: -total, else: total
  end

  # ---------------------------------------------------------------------------
  # Hit trajectory projection
  # ---------------------------------------------------------------------------

  @doc """
  How far does the given character fly, assuming they've been hit?

  Only considers air movement, not ground sliding. Projection ends if
  hitstun ends, or if a platform is encountered.

  `frames` of -1 (the default) means "until end of hitstun".

  Returns `{x, y, frame_count}`: the place the character ends up, plus
  frames until that position.

  Platform collision doesn't take ECB changes into account, so collision
  timing can be off by a couple frames.
  """
  @spec project_hit_location(PlayerState.t(), Stages.stage(), integer()) ::
          {number(), number(), integer()}
  def project_hit_location(%PlayerState{} = character_state, stage, frames \\ -1) do
    chardata = character_data(character_state.character)
    termvelocity = chardata["TerminalVelocity"]
    gravity = chardata["Gravity"]

    # List of all platforms, tuples of {height, left, right}
    edge = Stages.edge_ground_position(stage)

    platforms =
      [{0, -edge, edge}] ++
        for {h, _l, _r} = plat <- [
              Stages.left_platform_position(stage),
              Stages.right_platform_position(stage)
            ],
            h != nil,
            do: plat

    speed_x = character_state.speed_x_attack / 1
    speed_y_attack = character_state.speed_y_attack / 1

    angle = :math.atan2(speed_x, speed_y_attack)
    horizontal_decay = abs(0.051 * :math.cos(-angle + :math.pi() / 2))
    vertical_decay = abs(0.051 * :math.sin(-angle + :math.pi() / 2))

    frames_left =
      if frames == -1, do: character_state.hitstun_frames_left, else: frames

    project_loop(
      %{
        x: character_state.position.x / 1,
        y: character_state.position.y / 1,
        speed_x: speed_x,
        speed_y_attack: speed_y_attack,
        speed_y_self: character_state.speed_y_self / 1
      },
      frames_left,
      # Always quit out after 180 iterations just in case, to avoid infinite loops
      180,
      %{
        platforms: platforms,
        ecb_bottom_y: character_state.ecb.bottom.y,
        gravity: gravity,
        termvelocity: termvelocity,
        horizontal_decay: horizontal_decay,
        vertical_decay: vertical_decay,
        hitstun: character_state.hitstun_frames_left
      }
    )
  end

  defp project_loop(st, frames_left, failsafe, env)
       when frames_left <= 0 or failsafe <= 0 do
    {st.x, st.y, env.hitstun}
  end

  defp project_loop(st, frames_left, failsafe, env) do
    # Check if the character will hit a platform.
    # We have two line segments: AB is the platform, CD is the character.
    c = {st.x, st.y + env.ecb_bottom_y}
    d = {st.x + st.speed_x, st.y + env.ecb_bottom_y + st.speed_y_attack + st.speed_y_self}

    hit =
      Enum.find(env.platforms, fn {height, left, right} ->
        intersect?({left, height}, {right, height}, c, d)
      end)

    case hit do
      {height, _l, _r} ->
        # speed_x/2 to assume we intersect halfway through. Wrong, but close enough.
        {st.x + st.speed_x / 2, height, 181 - failsafe}

      nil ->
        x = st.x + st.speed_x
        y = st.y + st.speed_y_attack + st.speed_y_self

        speed_y_self = max(-env.termvelocity, st.speed_y_self - env.gravity)

        speed_y_attack =
          if st.speed_y_attack > 0,
            do: max(0, st.speed_y_attack - env.vertical_decay),
            else: min(0, st.speed_y_attack + env.vertical_decay)

        speed_x =
          if st.speed_x > 0,
            do: max(0, st.speed_x - env.horizontal_decay),
            else: min(0, st.speed_x + env.horizontal_decay)

        project_loop(
          %{
            x: x,
            y: y,
            speed_x: speed_x,
            speed_y_attack: speed_y_attack,
            speed_y_self: speed_y_self
          },
          frames_left - 1,
          failsafe - 1,
          env
        )
    end
  end

  # True if line segments AB and CD intersect
  defp intersect?(a, b, c, d) do
    ccw(a, c, d) != ccw(b, c, d) and ccw(a, b, c) != ccw(a, b, d)
  end

  defp ccw({ax, ay}, {bx, by}, {cx, cy}) do
    (cy - ay) * (bx - ax) > (by - ay) * (cx - ax)
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp char_id(character) when is_integer(character), do: character
  defp char_id(character), do: Character.to_id(character)

  defp action_id(action) when is_integer(action), do: action
  defp action_id(action), do: Action.to_id(action)

  defp frames_for(character, action) do
    Map.get(framedata(), {char_id(character), action_id(action)}, %{})
  end

  # Frames of an action that have any hitbox (or projectile) active.
  defp hitbox_frames(character, action) do
    for {frame, tuple} <- frames_for(character, action), hitbox_frame?(tuple), do: frame
  end

  defp hitbox_frame?(tuple), do: hitbox_active?(tuple) or elem(tuple, @idx_projectile)

  defp hitbox_active?(tuple),
    do: elem(tuple, 0) or elem(tuple, 4) or elem(tuple, 8) or elem(tuple, 12)

  defp frame_tuple_to_map(
         {h1s, h1sz, h1x, h1y, h2s, h2sz, h2x, h2y, h3s, h3sz, h3x, h3y, h4s, h4sz, h4x, h4y,
          locox, locoy, iasa, fc, proj}
       ) do
    %{
      hitbox_1_status: h1s,
      hitbox_1_size: h1sz,
      hitbox_1_x: h1x,
      hitbox_1_y: h1y,
      hitbox_2_status: h2s,
      hitbox_2_size: h2sz,
      hitbox_2_x: h2x,
      hitbox_2_y: h2y,
      hitbox_3_status: h3s,
      hitbox_3_size: h3sz,
      hitbox_3_x: h3x,
      hitbox_3_y: h3y,
      hitbox_4_status: h4s,
      hitbox_4_size: h4sz,
      hitbox_4_x: h4x,
      hitbox_4_y: h4y,
      locomotion_x: locox,
      locomotion_y: locoy,
      iasa: iasa,
      facing_changed: fc,
      projectile: proj
    }
  end
end
