defmodule Melee.MenuHelper do
  @moduledoc """
  Helper for navigating the Melee menus in ways that would be cumbersome
  to do on your own. The goal here is to get you into the game as easily
  as possible so you don't have to worry about it. Your AI should
  concentrate on playing the game, not futzing with menus.

  Port of libmelee's stateful `MenuHelper` (vladfi1's fork, v0.43.0).
  Build the navigation state with `new/0`, then call `step/4` once per
  frame with the current `Melee.GameState`; it presses buttons on the
  given `Melee.Controller` and returns the updated state.

      helper = Melee.MenuHelper.new()

      # each frame:
      helper =
        Melee.MenuHelper.step(helper, gamestate, controller,
          character: 0x01,   # Fox (internal id)
          stage: 0x19,       # Final Destination (internal id)
          cpu_level: 0,
          autostart: true
        )

  Character and stage are the RAW INTERNAL integer ids used throughout
  this library (see `Melee.Enums.Character` / `Melee.Enums.Stage`).
  """

  alias Melee.{Controller, GameState}
  alias Melee.Enums.{Character, Stage}

  # Menu wire values (Melee.Enums.Menu)
  @character_select 0
  @stage_select 1
  @postgame_scores 4
  @main_menu 5
  @slippi_online_css 6
  @press_start 7

  # SubMenu wire values (Melee.Enums.SubMenu)
  @main_menu_submenu 0
  @onep_mode_submenu 1
  @vs_mode_submenu 2
  @online_play_submenu 8
  @name_entry_submenu 18
  # Melee.Events.Menu reports the Slippi online CSS name-entry overlay
  # with the raw scene byte 0x05 rather than remapping it to 18.
  @online_name_entry_submenu 0x05

  # ControllerStatus wire values
  @controller_cpu 1

  @typedoc """
  Menu-navigation state. Mirrors the Python instance attributes:
  connect-code entry progress (`name_tag_index`, `inputs_live`) and
  stage-select progress (`frames_on_stage`, `frozen_stadium_selected`,
  `stage_selected`).
  """
  @type t :: %__MODULE__{
          name_tag_index: non_neg_integer(),
          inputs_live: boolean(),
          frames_on_stage: non_neg_integer(),
          frozen_stadium_selected: boolean(),
          stage_selected: boolean()
        }

  defstruct name_tag_index: 0,
            inputs_live: false,
            frames_on_stage: 0,
            frozen_stadium_selected: false,
            stage_selected: false

  @doc """
  Fresh menu-navigation state.

  ## Examples

      iex> Melee.MenuHelper.new()
      %Melee.MenuHelper{
        name_tag_index: 0,
        inputs_live: false,
        frames_on_stage: 0,
        frozen_stadium_selected: false,
        stage_selected: false
      }
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Run one frame of menu navigation: press buttons on `controller` to get
  through the menus and into a game, exactly as Python libmelee's
  `MenuHelper.menu_helper_simple` does. Returns the updated state.

  Does nothing (returns the state unchanged, no controller writes) when
  the gamestate is in-game.

  Options:

    * `:character` (required) — internal character id (e.g. Fox `0x01`)
    * `:stage` (required) — internal stage id (e.g. FD `0x19`)
    * `:connect_code` — Slippi connect code; `nil` (default) for local
      play. With `nil`, the name-entry screen is left alone (a human can
      use it); an explicit `""` still drives the direct-code keyboard —
      the nil/"" distinction matches upstream v0.47 semantics.
    * `:cpu_level` — CPU level to configure, `0` (default) for human/bot
    * `:costume` — costume index (default `0`)
    * `:autostart` — press START when the match is ready (default `false`)
    * `:swag` — what it sounds like (default `false`)
    * `:frozen_stadium` — toggle Frozen Stadium at stage select
      (default `true`, matching Python; only meaningful with autostart)
    * `:port` — the controller port we are driving (default `1`).
      Python reads this off the `Controller` object; ours doesn't carry
      a port, so pass it here when not on port 1.
  """
  @spec step(t(), GameState.t(), GenServer.server(), keyword()) :: t()
  def step(%__MODULE__{} = state, %GameState{} = gamestate, controller, opts) do
    character = Keyword.fetch!(opts, :character)
    stage = Keyword.fetch!(opts, :stage)
    connect_code = Keyword.get(opts, :connect_code, nil)
    cpu_level = Keyword.get(opts, :cpu_level, 0)
    costume = Keyword.get(opts, :costume, 0)
    autostart = Keyword.get(opts, :autostart, false)
    swag = Keyword.get(opts, :swag, false)
    frozen_stadium = Keyword.get(opts, :frozen_stadium, true)
    port = Keyword.get(opts, :port, 1)

    cond do
      gamestate.menu_state in [@character_select, @slippi_online_css] ->
        if name_entry?(gamestate) do
          # v0.47 semantics: nil = leave name entry alone (local play);
          # any string (even "") drives the direct-code keyboard.
          if connect_code != nil do
            enter_direct_code(state, gamestate, controller, connect_code)
          else
            state
          end
        else
          # We've exited the name entry screen, so reset the state in case
          # we go back
          state = %{state | name_tag_index: 0, inputs_live: false}

          choose_character(
            state,
            gamestate,
            controller,
            character,
            port,
            cpu_level,
            costume,
            swag,
            autostart
          )
        end

      # If we're at the postgame scores screen, spam START
      gamestate.menu_state == @postgame_scores ->
        skip_postgame(state, controller)

      gamestate.menu_state == @stage_select ->
        choose_stage(
          state,
          gamestate,
          controller,
          stage,
          character,
          frozen_stadium,
          autostart,
          port
        )

      # Python's menu_helper_simple only routes MAIN_MENU here, but both
      # choose_versus_mode and choose_direct_online handle PRESS_START
      # (spamming START); routing PRESS_START through them preserves that
      # behavior for callers using this single entry point.
      gamestate.menu_state in [@main_menu, @press_start] ->
        if connect_code in [nil, ""] do
          choose_versus_mode(gamestate, controller)
        else
          choose_direct_online(gamestate, controller)
        end

        state

      # In-game (or unknown scene): do nothing
      true ->
        state
    end
  end

  ## Name entry (Slippi direct connect code)

  defp name_entry?(%GameState{menu_state: menu, submenu: submenu}) do
    submenu == @name_entry_submenu or
      (menu == @slippi_online_css and submenu == @online_name_entry_submenu)
  end

  # At the nametag entry screen, enter the given direct connect code and
  # exit. Port of MenuHelper.enter_direct_code.
  defp enter_direct_code(state, gamestate, controller, connect_code) do
    # The name entry screen is dead for the first few frames
    #   So if the first character is A, then the input can get eaten
    #   Account for this by making sure we can move off the letter first
    state =
      if gamestate.menu_selection != 45, do: %{state | inputs_live: true}, else: state

    cond do
      not state.inputs_live ->
        Controller.tilt_analog(controller, :main, 1.0, 0.5)
        state

      # Let the controller go every other frame. Makes the logic below easier
      Integer.mod(gamestate.frame, 2) == 0 ->
        Controller.release_all(controller)
        state

      String.length(connect_code) == state.name_tag_index ->
        Controller.press_button(controller, :start)
        state

      true ->
        target_code =
          connect_code
          |> String.at(state.name_tag_index)
          |> name_entry_target_code()

        do_enter_code_char(state, gamestate, controller, target_code)
    end
  end

  defp do_enter_code_char(state, gamestate, controller, target_code) do
    selection = gamestate.menu_selection

    cond do
      selection == target_code ->
        Controller.press_button(controller, :a)
        %{state | name_tag_index: state.name_tag_index + 1}

      selection == 57 ->
        Controller.tilt_analog(controller, :main, 0.5, 1.0)
        state

      # If the target is greater than our position, move down / left
      selection <= target_code - 5 ->
        # If the diff is less than 5, then move vertically
        if abs(target_code - selection) < 5 do
          Controller.tilt_analog(controller, :main, 0.5, 0.0)
        else
          Controller.tilt_analog(controller, :main, 0.0, 0.5)
        end

        state

      # If the target is less than our position, move up / right
      true ->
        if abs(target_code - selection) < 5 do
          Controller.tilt_analog(controller, :main, 0.5, 1.0)
        else
          Controller.tilt_analog(controller, :main, 1.0, 0.5)
        end

        state
    end
  end

  # Sequential row lookups, exactly like the Python (later rows override).
  defp name_entry_target_code(char) do
    45
    |> row_code("ABCDEFGHIJ", char, 45)
    |> row_code("KLMNOPQRST", char, 46)
    |> row_code("UVWXYZ   #", char, 47)
    |> row_code("0123456789", char, 48)
  end

  defp row_code(default, row, char, base) do
    case :binary.match(row, char) do
      {column, _} -> base - column * 5
      :nomatch -> default
    end
  end

  ## Character select

  # Port of MenuHelper.choose_character. Never mutates the helper state.
  defp choose_character(
         state,
         gamestate,
         controller,
         character_id,
         port,
         cpu_level,
         costume,
         swag,
         start
       ) do
    # Figure out where the character is on the select screen
    # NOTE: This assumes you have all characters unlocked
    if Map.has_key?(gamestate.players, port) do
      do_choose_character(
        state,
        gamestate,
        controller,
        character_id,
        port,
        cpu_level,
        costume,
        swag,
        start
      )
    else
      Controller.release_all(controller)
      state
    end
  end

  defp do_choose_character(
         state,
         gamestate,
         controller,
         character_id,
         port,
         cpu_level,
         costume,
         swag,
         start
       ) do
    # Discover who is the opponent: the first controller port that isn't us
    opponent_state =
      gamestate.players
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.find_value(fn {p, player} -> if p != port, do: player end)

    slippi_css? = gamestate.menu_state == @slippi_online_css

    {ai_state, swag} =
      if slippi_css? do
        if cpu_level != 0, do: raise(ArgumentError, "Can't choose CPU in netplay.")
        {Map.fetch!(gamestate.players, 1), true}
      else
        {Map.fetch!(gamestate.players, port), swag}
      end

    %{x: cursor_x, y: cursor_y} = ai_state.cursor
    coin_down = ai_state.coin_down

    use_cpu = cpu_level > 0
    character = Character.from_id(character_id)

    # In netplay, there is a toggle near the character portrait for switching
    # between Sheik and Zelda which (sensibly) defaults to Sheik.
    if slippi_css? and character == :zelda do
      raise ArgumentError, "Picking Zelda in netplay is unsupported."
    end

    # To play as Sheik, you select Zelda and then hold A after selecting
    # the stage.
    target_character =
      if character == :sheik do
        if use_cpu, do: raise(ArgumentError, "We can't force the CPU to pick Sheik.")
        :zelda
      else
        character
      end

    correct_character = ai_state.character == Character.to_id(target_character)

    external = Character.from_internal(target_character)
    row = div(external, 9)
    column = rem(external, 9)
    # The random slot pushes the bottom row over a slot, so compensate for that
    column = if row == 2, do: column + 1, else: column
    # re-order rows so the math is simpler
    row = 2 - row

    # Go to the random character
    {row, column} = if swag, do: {0, 0}, else: {row, column}

    # Height starts at 1, plus half a box height, plus the number of rows
    target_y = 1 + 3.5 + row * 7.0
    # Starts at -32.5, plus half a box width, plus the number of columns
    # NOTE: Technically, each column isn't exactly the same width, but it's
    # close enough
    target_x = -32.5 + 3.5 + column * 7.0
    # Wiggle room in positioning character
    wiggleroom = 1.5

    cond do
      # Set our CPU level correctly. Parenthesization matches Python's
      # operator precedence: (... and ... and ...) or is_holding_cpu_slider
      (use_cpu and correct_character and (coin_down or cursor_y < 0) and
         cpu_level != ai_state.cpu_level) or ai_state.is_holding_cpu_slider ->
        if slippi_css?, do: raise(ArgumentError, "CPU slider state during netplay CSS")
        configure_cpu(gamestate, controller, ai_state, port, cpu_level, use_cpu)
        state

      # We are already set, so let's taunt our opponent
      correct_character and swag and opponent_state != nil and not start ->
        taunt_opponent(gamestate, controller, opponent_state, cursor_x, cursor_y)
        state

      correct_character and swag and slippi_css? ->
        if Integer.mod(gamestate.frame, 2) == 0 do
          Controller.release_all(controller)
        else
          if costume == ai_state.costume do
            Controller.press_button(controller, :start)
          else
            Controller.press_button(controller, :y)
          end
        end

        state

      true ->
        select_character(
          state,
          gamestate,
          controller,
          ai_state,
          {target_x, target_y, wiggleroom},
          correct_character,
          slippi_css?,
          start
        )
    end
  end

  # The CPU-configuration state machine: walk to the HMN/CPU box, press A,
  # walk to the slider, grab it, drag it to the wanted level, release.
  defp configure_cpu(gamestate, controller, ai_state, port, cpu_level, use_cpu) do
    %{x: cursor_x, y: cursor_y} = ai_state.cursor
    cpu_selected = ai_state.controller_status == @controller_cpu

    cond do
      # Is our controller type correct?
      cpu_selected != use_cpu ->
        wiggleroom = 1
        target_y = -2.2
        target_x = -32.2 + 15.82 * (port - 1)

        Controller.release_button(controller, :a)

        cond do
          # Move up if we're too low
          cursor_y < target_y - wiggleroom ->
            Controller.tilt_analog(controller, :main, 0.5, 1.0)

          # Move down if we're too high
          cursor_y > target_y + wiggleroom ->
            Controller.tilt_analog(controller, :main, 0.5, 0.0)

          # Move right if we're too left
          cursor_x < target_x - wiggleroom ->
            Controller.tilt_analog(controller, :main, 1.0, 0.5)

          # Move left if we're too right
          cursor_x > target_x + wiggleroom ->
            Controller.tilt_analog(controller, :main, 0.0, 0.5)

          Integer.mod(gamestate.frame, 2) == 0 ->
            Controller.press_button(controller, :a)

          true ->
            Controller.release_all(controller)
        end

      # Select the right CPU level on the slider
      ai_state.is_holding_cpu_slider ->
        cond do
          ai_state.cpu_level > cpu_level ->
            Controller.tilt_analog(controller, :main, 0.35, 0.5)

          ai_state.cpu_level < cpu_level ->
            Controller.tilt_analog(controller, :main, 0.65, 0.5)

          Integer.mod(gamestate.frame, 2) == 0 ->
            Controller.press_button(controller, :a)

          true ->
            Controller.release_all(controller)
        end

      # Move over to and pick up the CPU slider
      ai_state.cpu_level != cpu_level ->
        wiggleroom = 1
        target_y = -15.12
        target_x = -30.9 + 15.4 * (port - 1)

        cond do
          cursor_y < target_y - wiggleroom ->
            Controller.tilt_analog(controller, :main, 0.5, 0.8)

          cursor_y > target_y + wiggleroom ->
            Controller.tilt_analog(controller, :main, 0.5, 0.2)

          cursor_x < target_x - wiggleroom ->
            Controller.tilt_analog(controller, :main, 0.8, 0.5)

          cursor_x > target_x + wiggleroom ->
            Controller.tilt_analog(controller, :main, 0.2, 0.5)

          Integer.mod(gamestate.frame, 2) == 0 ->
            Controller.press_button(controller, :a)

          true ->
            Controller.release_all(controller)
        end

      true ->
        :ok
    end
  end

  # Wave the cursor around the opponent's cursor in a circle.
  defp taunt_opponent(gamestate, controller, opponent_state, cursor_x, cursor_y) do
    delta_x = 3 * :math.cos(gamestate.frame / 1.5)
    delta_y = 3 * :math.sin(gamestate.frame / 1.5)

    target_x = opponent_state.cursor.x + delta_x
    target_y = opponent_state.cursor.y + delta_y

    diff_x = abs(target_x - cursor_x)
    diff_y = abs(target_y - cursor_y)
    larger_magnitude = max(diff_x, diff_y)

    # Scale down values to between 0 and 1
    x = diff_x / larger_magnitude
    y = diff_y / larger_magnitude

    # Now scale down to be between .5 and 1
    x = if cursor_x < target_x, do: x / 2 + 0.5, else: 0.5 - x / 2
    y = if cursor_y < target_y, do: y / 2 + 0.5, else: 0.5 - y / 2

    Controller.tilt_analog(controller, :main, x, y)
  end

  # The core "move to the portrait and press A" flow.
  defp select_character(
         state,
         gamestate,
         controller,
         ai_state,
         {target_x, target_y, wiggleroom},
         correct_character,
         slippi_css?,
         start
       ) do
    %{x: cursor_x, y: cursor_y} = ai_state.cursor
    coin_down = ai_state.coin_down
    prev = Controller.prev(controller)

    # We want to get to a state where the cursor is NOT over the character,
    # but it's selected. Thus ensuring the token is on the character
    over_character? =
      abs(cursor_x - target_x) < wiggleroom and abs(cursor_y - target_y) < wiggleroom

    cond do
      # Don't hold down on B, since we'll quit the menu if we do
      prev.button.b ->
        Controller.release_button(controller, :b)

      # If character is selected, and we're in the area, and coin is down,
      # then we're good
      correct_character and coin_down ->
        cond do
          Integer.mod(gamestate.frame, 2) == 0 ->
            Controller.release_all(controller)

          # Python checks `ready_to_start == 0` on the raw byte; our
          # GameState carries the boolean "ready banner is up".
          start and gamestate.ready_to_start ->
            Controller.press_button(controller, :start)

          true ->
            Controller.release_all(controller)
        end

      true ->
        # release start in addition to anything else
        Controller.release_button(controller, :start)

        if over_character? do
          # If we're over the character, but it isn't selected, then the
          # coin must be somewhere else. Press B to reclaim the coin
          Controller.tilt_analog(controller, :main, 0.5, 0.5)

          cond do
            # The slippi menu doesn't have a coin down. We can make-do
            slippi_css? and not correct_character ->
              if Integer.mod(gamestate.frame, 5) == 0 do
                Controller.press_button(controller, :b)
                Controller.release_button(controller, :a)
              else
                Controller.press_button(controller, :a)
                Controller.release_button(controller, :b)
              end

            not correct_character and coin_down ->
              Controller.press_button(controller, :b)
              Controller.release_button(controller, :a)

            # Press A to select our character
            true ->
              if prev.button.a == false do
                Controller.press_button(controller, :a)
              else
                Controller.release_button(controller, :a)
              end
          end
        else
          # Move in
          Controller.release_button(controller, :a)

          cond do
            # Move up if we're too low
            cursor_y < target_y - wiggleroom ->
              Controller.tilt_analog(controller, :main, 0.5, 1.0)

            # Move down if we're too high
            cursor_y > target_y + wiggleroom ->
              Controller.tilt_analog(controller, :main, 0.5, 0.0)

            # Move right if we're too left
            cursor_x < target_x - wiggleroom ->
              Controller.tilt_analog(controller, :main, 1.0, 0.5)

            # Move left if we're too right
            cursor_x > target_x + wiggleroom ->
              Controller.tilt_analog(controller, :main, 0.0, 0.5)

            # Unreachable given over_character? is false, but Python ends
            # with an unconditional release_all here; keep it.
            true ->
              Controller.release_all(controller)
          end
        end
    end

    state
  end

  ## Stage select

  # Stage-select cursor targets, copied exactly from menuhelper.py.
  @stage_targets %{
    battlefield: {1, -9},
    final_destination: {6.7, -9},
    dreamland: {12.5, -9},
    pokemon_stadium: {15, 3.5},
    yoshis_story: {3.5, 15.5},
    fountain_of_dreams: {10, 15.5},
    random_stage: {-13.5, 3.5}
  }

  # Port of MenuHelper.choose_stage.
  defp choose_stage(
         state,
         gamestate,
         controller,
         stage_id,
         character_id,
         frozen_stadium,
         autostart,
         port
       ) do
    state = if gamestate.frame == 0, do: %{state | stage_selected: false}, else: state

    cond do
      state.stage_selected or not autostart ->
        # Select Sheik during local play.
        if Character.from_id(character_id) == :sheik do
          Controller.press_button(controller, :a)
        else
          Controller.release_all(controller)
        end

        state

      gamestate.frame < 20 ->
        Controller.release_all(controller)
        state

      true ->
        navigate_stage_select(state, gamestate, controller, stage_id, frozen_stadium, port)
    end
  end

  defp navigate_stage_select(state, gamestate, controller, stage_id, frozen_stadium, port) do
    {target_x, target_y} = Map.get(@stage_targets, Stage.from_id(stage_id), {0, 0})
    # Wiggle room in positioning cursor
    wiggleroom = 1.5
    %{x: cursor_x, y: cursor_y} = Map.fetch!(gamestate.players, port).cursor

    cond do
      # Move up if we're too low
      cursor_y < target_y - wiggleroom ->
        Controller.release_button(controller, :a)
        Controller.tilt_analog(controller, :main, 0.5, 1.0)
        state

      # Move down if we're too high
      cursor_y > target_y + wiggleroom ->
        Controller.release_button(controller, :a)
        Controller.tilt_analog(controller, :main, 0.5, 0.0)
        state

      # Move right if we're too left
      cursor_x < target_x - wiggleroom ->
        Controller.release_button(controller, :a)
        Controller.tilt_analog(controller, :main, 1.0, 0.5)
        state

      # Move left if we're too right
      cursor_x > target_x + wiggleroom ->
        Controller.release_button(controller, :a)
        Controller.tilt_analog(controller, :main, 0.0, 0.5)
        state

      true ->
        # If we get in the right area, press A
        Controller.tilt_analog(controller, :main, 0.5, 0.5)
        state = %{state | frames_on_stage: state.frames_on_stage + 1}
        maybe_toggle_frozen_stadium(state, controller, frozen_stadium)
    end
  end

  # Empirically, it seems that we can toggle Frozen Stadium when the
  # cursor is on any stage. So, we toggle at the first opportunity and
  # leave it like that, whether or not we're currently selecting Stadium.
  defp maybe_toggle_frozen_stadium(state, controller, frozen_stadium) do
    if frozen_stadium != state.frozen_stadium_selected do
      # Frame numbers here are probably quite loose.
      case state.frames_on_stage do
        30 -> Controller.press_button(controller, :z)
        40 -> Controller.release_button(controller, :z)
        _ -> :ok
      end

      if state.frames_on_stage < 60 do
        state
      else
        state = %{state | frozen_stadium_selected: frozen_stadium}
        select_stage(state, controller)
      end
    else
      select_stage(state, controller)
    end
  end

  defp select_stage(state, controller) do
    Controller.press_button(controller, :a)
    %{state | stage_selected: true, frames_on_stage: 0}
  end

  ## Postgame

  # Spam the start button: alternate pressing start and letting go.
  defp skip_postgame(state, controller) do
    if Controller.prev(controller).button.start == false do
      Controller.press_button(controller, :start)
    else
      Controller.release_button(controller, :start)
    end

    state
  end

  ## Main menu navigation

  # Port of MenuHelper.choose_versus_mode: bring us into the versus mode
  # menu (also spams START at the PRESS_START scene).
  defp choose_versus_mode(gamestate, controller) do
    cond do
      # Let the controller go every other frame. Makes the logic below easier
      Integer.mod(gamestate.frame, 2) == 0 ->
        Controller.release_all(controller)

      gamestate.menu_state == @main_menu ->
        case gamestate.submenu do
          @main_menu_submenu ->
            if gamestate.menu_selection == 1 do
              Controller.press_button(controller, :a)
            else
              Controller.tilt_analog(controller, :main, 0.5, 0.0)
            end

          @vs_mode_submenu ->
            if gamestate.menu_selection == 0 do
              Controller.press_button(controller, :a)
            else
              Controller.tilt_analog(controller, :main, 0.5, 0.0)
            end

          _ ->
            Controller.press_button(controller, :b)
        end

      gamestate.menu_state == @press_start ->
        Controller.press_button(controller, :start)

      true ->
        Controller.release_all(controller)
    end
  end

  # Port of MenuHelper.choose_direct_online: bring us into the direct
  # connect online menu (also spams START at the PRESS_START scene).
  defp choose_direct_online(gamestate, controller) do
    cond do
      # Let the controller go every other frame. Makes the logic below easier
      Integer.mod(gamestate.frame, 2) == 0 ->
        Controller.release_all(controller)

      gamestate.menu_state == @main_menu ->
        case gamestate.submenu do
          @online_play_submenu ->
            if gamestate.menu_selection in [2, 3] do
              Controller.press_button(controller, :a)
            else
              Controller.tilt_analog(controller, :main, 0.5, 0.0)
            end

          @main_menu_submenu ->
            Controller.press_button(controller, :a)

          @onep_mode_submenu ->
            if gamestate.menu_selection == 2 do
              Controller.press_button(controller, :a)
            else
              Controller.tilt_analog(controller, :main, 0.5, 0.0)
            end

          @name_entry_submenu ->
            :ok

          _ ->
            Controller.press_button(controller, :b)
        end

      gamestate.menu_state == @press_start ->
        Controller.press_button(controller, :start)

      true ->
        Controller.release_all(controller)
    end
  end
end
