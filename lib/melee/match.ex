defmodule Melee.Match do
  @moduledoc """
  One call from wherever the game is to a running match.

  Driving Melee's menus correctly takes more than `Melee.MenuHelper`'s
  per-port mechanics: the ports have to be COORDINATED, and every rule
  below was learned from a live stall (see `docs/melee-menus.md`):

    * READY TO FIGHT comes up the instant a second port is filled, well
      before a CPU level finishes configuring — so the leader's
      `autostart` is gated on every other port being configured;
    * that gate (and every cross-port gate) may only bite AT the
      character select screen: past it the gamestate stops reporting
      CSS fields, and a gate that stays false there strands the run at
      stage select;
    * the nametag flow interrupts the CSS and Melee relocates every
      other hand — a port mid-slider-drag gets yanked off one level
      short — so the nametag is withheld until the other ports are
      done.

  `play/2` encodes all of it:

      {:ok, session} = Melee.Session.start_link(path: ..., iso_path: ..., ...)

      {:ok, gamestate} =
        Melee.Match.play(session,
          p1: [character: :fox, nametag: "EXPH", nametag_mode: :select],
          p2: [character: :falco, cpu_level: 9],
          stage: :final_destination
        )

  Characters and stages accept `Melee.Enums` atoms or raw ids. The
  first port listed is the LEADER: it presses START and owns the
  nametag. Every port in the spec must be in the session's `:ports`.

  ## Doubles

  Pass `teams: true` and per-port `team:` colors for a Team Battle:

      Melee.Match.play(session,
        teams: true,
        p1: [character: :fox],
        p2: [character: :falco],
        p3: [character: :marth, team: :blue],
        p4: [character: :peach, team: :blue],
        stage: :battlefield
      )

  The flow encodes the measured mechanics (docs/melee-menus.md "Team
  Battle"): all picks land first (coins DOWN — a held token cannot
  press UI), the leader's empty hand toggles the mode, each port taps
  its color chip the counted number of times (`:red` default -> 0,
  `:blue` 1, `:green` 2), and `ready_to_start` gates the start — an
  all-one-team spec fails with `{:error, :teams_never_ready}` instead
  of hanging.

  CAVEAT: the mode and colors PERSIST across matches in a Dolphin
  session and have no CSS readback, so teams plays are deterministic
  from a FRESH session; verify after the fact with `gamestate.is_teams`
  and per-player `team_id`.

  ## Custom Rules

  Pass `rules:` to set the VS Custom Rules screen on the way in:

      Melee.Match.play(session,
        rules: [stock: 1, time_limit: 5, team_attack: true],
        p1: [character: :fox],
        p2: [character: :falco, cpu_level: 9],
        stage: :final_destination)

    * `:stock` — stock count, 1..99 (fresh-session default 4);
    * `:time_limit` — Stock Time Limit in minutes, 1..99 (default 8);
    * `:team_attack` — ally damage in a Team Battle. These Dolphin
      builds default it ON (vanilla Melee defaults OFF — measured
      otherwise here, and behaviorally verified: an ally dash-attack
      deals 9% by default and 0% with `team_attack: false`). Note
      Fox's reflector hits allies even when OFF, one of Melee's
      TA-off exceptions alongside grabs;
    * `:pause` — `false` disables mid-game pausing (useful under
      training so a stray START cannot freeze the frame stream), BUT
      the LRAS quit-out rides the pause menu, so `Melee.Match.quit/3`
      times out in a pause-disabled game — the episode then has to
      end by stocks or timer;
    * `:item_frequency` — `:none` (the fresh-session default: items
      never spawn) or `:very_low` / `:low` / `:medium` / `:high` /
      `:very_high`. Read back as `gamestate.item_frequency`
      (`nil` = off, 0..4 otherwise);
    * `:items` — the ONLY items allowed to spawn, as
      `Melee.Enums.ProjectileType` atoms or raw ids
      (`items: [:poke_ball]` for a Poke Ball-only match); every other
      Item Switch cell is toggled off. Containers (capsule / box /
      barrel / egg) are not in the switch and keep spawning — holding
      whatever is enabled. Read back as `gamestate.item_bitfield`
      (bit index == item id). Only meaningful with an
      `:item_frequency` above `:none`.

  Row navigation is closed-loop on `menu_selection`, but the VALUES
  have no menu readback, so they are set open-loop by counted taps
  from the fresh-session defaults — the same caveat as teams: rules
  persist across matches in a Dolphin session, so pass `rules:` on the
  FIRST `play/2` of a session only (later plays in a session keep
  them; a `play/2` asked for rules past the VS menu returns
  `{:error, :rules_need_fresh_menu}`). Verify after the fact from
  GAME_START: `players[n].stock`, `gamestate.timer` (seconds),
  `gamestate.is_team_attack` and `gamestate.pause_enabled`.

  Returns `{:ok, gamestate}` with the first in-game frame — hand the
  loop to your bot from there (or use `Melee.Bot`, which wraps this).
  """

  alias Melee.{Cursor, Enums, GameState, MenuHelper, Session}

  @controller_cpu Enums.ControllerStatus.to_id(:controller_cpu)

  @type port_spec :: [
          {:character, atom() | integer()}
          | {:cpu_level, 1..9}
          | {:nametag, String.t()}
          | {:nametag_mode, :create | :select}
          | {:team, :red | :blue | :green}
        ]

  @type rules_spec :: [
          {:stock, 1..99}
          | {:time_limit, 1..99}
          | {:team_attack, boolean()}
          | {:pause, boolean()}
          | {:item_frequency, :none | :very_low | :low | :medium | :high | :very_high}
          | {:items, [atom() | integer()]}
        ]

  @doc """
  Drive the session's menus until a match is running.

  Options: `:p1`..`:p4` port specs (at least one), `:stage` (atom or
  id, required), `:teams` (default `false` — see "Doubles"),
  `:rules` (default `[]` — see "Custom Rules"), `:timeout_frames`
  (default `20_000`).

  Returns `{:ok, gamestate}` (first in-game frame),
  `{:error, {:timeout, gamestate}}` if the match never starts, or
  `{:error, reason}` if the session's console fails.
  """
  @spec play(GenServer.server(), keyword()) ::
          {:ok, GameState.t()} | {:error, term()}
  # Team Battle coordinates, measured live 2026-08-17 (see
  # docs/melee-menus.md "Team Battle").
  @teams_toggle {-29.7, 24.2}
  @team_chip_x -25.7
  @team_chip_y -1.9
  @panel_spacing 15.82

  def play(session, opts) do
    stage = resolve!(Enums.Stage, Keyword.fetch!(opts, :stage))
    timeout_frames = Keyword.get(opts, :timeout_frames, 20_000)
    teams? = Keyword.get(opts, :teams, false)

    specs =
      for {key, gc_port} <- [p1: 1, p2: 2, p3: 3, p4: 4],
          spec = Keyword.get(opts, key),
          do: {gc_port, normalize_spec(spec, gc_port, stage, teams?)}

    if specs == [], do: raise(ArgumentError, "Melee.Match.play/2 needs at least one port spec")

    controllers =
      Map.new(specs, fn {gc_port, _} -> {gc_port, Session.controller(session, gc_port)} end)

    helpers = Map.new(specs, fn {gc_port, _} -> {gc_port, MenuHelper.new()} end)

    rules = Keyword.get(opts, :rules, [])

    with {:ok, helpers} <- set_rules(session, specs, controllers, helpers, rules, timeout_frames) do
      if teams? do
        play_teams(session, specs, controllers, helpers, timeout_frames)
      else
        loop(session, specs, controllers, helpers, timeout_frames)
      end
    end
  end

  # ------------------------------------------------------------------
  # Custom Rules (menu 5, submenu 13 — mapped headless 2026-08-17,
  # tmp/rules_map.exs / tmp/rules_diff.exs). Row NAVIGATION is fully
  # observable via `menu_selection` (rows 0-6, wrapping; Additional
  # Rules is its own screen behind row 6, submenu reading 0xFF, rows
  # 0-5). Row VALUES are invisible in the gamestate, so they are set
  # OPEN-LOOP by counted left/right taps from the fresh-session
  # defaults (stock 4, Stock Time Limit 8:00, Team Attack ON, Pause
  # ON) and verified after the fact from GAME_START
  # (`players[n].stock`, `gamestate.timer`, `gamestate.is_team_attack`,
  # `gamestate.pause_enabled`).
  #
  # Melee list menus act on stick EDGES: 2 frames of tilt, ~10 of
  # release (the same cadence MenuHelper's choose_versus_mode uses).

  @vs_row_custom_rules 3
  @custom_rules_submenu 13
  @vs_mode_submenu 2
  @main_menu 5
  @rules_row_stock 1
  @rules_row_items 5
  @rules_row_additional 6
  # The Item Switch grid is two 16-tall columns (left cells 0-15,
  # right 16-30; a right-nudge moves +16 within a row) with the
  # frequency dial reachable below the left column as selection 31
  # (and above the right column as 32 — same dial). The dial cycles
  # very_low(0)..very_high(4), none; a LEFT tap from the none default
  # lands very_low, a RIGHT tap very_high.
  @item_switch_frequency_row 31

  # Item Switch cell (selection id) per item id, from the full one-A-
  # tap-per-cell GAME_START byte-diff sweep (tmp/items_cells.exs) plus
  # spawn identification of three isolated cells (tmp/items_spawn.exs):
  # the mask bit index IS the item id, so each diffed bit named its
  # cell. Ids are Melee.Enums.ProjectileType's common-item block;
  # containers (capsule/box/barrel/egg, 0-3) are not in the switch.
  @item_cell_by_id %{
    0x04 => 30,
    0x05 => 29,
    0x06 => 19,
    0x07 => 17,
    0x08 => 2,
    0x09 => 1,
    0x0A => 23,
    0x0B => 10,
    0x0C => 9,
    0x0D => 24,
    0x0E => 13,
    0x0F => 14,
    0x10 => 4,
    0x11 => 16,
    0x12 => 0,
    0x13 => 20,
    0x14 => 15,
    0x15 => 5,
    0x16 => 8,
    0x17 => 7,
    0x18 => 11,
    0x19 => 6,
    0x1A => 21,
    0x1B => 22,
    0x1C => 12,
    0x1D => 3,
    0x1E => 25,
    0x1F => 27,
    0x20 => 26,
    0x21 => 28,
    0x22 => 18
  }

  # Frequency dial taps from the fresh-session `none` default; right
  # walks very_high(4), high(3)...; left walks very_low(0), low(1)...
  @item_frequency_taps %{
    none: 0,
    very_low: -1,
    low: -2,
    medium: -3,
    high: 2,
    very_high: 1
  }
  @additional_row_time_limit 0
  # Rows pinned BEHAVIORALLY (tmp/ta_probe.exs): a right-tap on row 1
  # made an ally dash-attack deal 0% instead of 9% (Team Attack
  # ON -> OFF), and a right-tap on row 2 made the LRAS quit-out time
  # out (Pause ON -> OFF — the quit rides the pause menu).
  @additional_row_team_attack 1
  @additional_row_pause 2
  # Fresh-session defaults the open-loop taps count from. Team Attack
  # and Pause both default ON on these Dolphin builds (vanilla Melee
  # defaults Team Attack OFF; measured otherwise here).
  @default_stock 4
  @default_time_limit_min 8

  defp set_rules(_session, _specs, _controllers, helpers, [], _timeout), do: {:ok, helpers}

  defp set_rules(session, [{leader, _} | _] = specs, controllers, helpers, rules, timeout_frames) do
    taps = rules_taps!(rules)
    controller = controllers[leader]

    # Ride the helpers to the VS Mode menu — but no further. The done?
    # check runs on each frame BEFORE the helpers act on it, so the
    # first frame reporting submenu 2 stops the drive before the
    # leader's helper can press A into the CSS.
    with {:ok, helpers, gamestate} <-
           drive_until(
             session,
             specs,
             controllers,
             helpers,
             fn gs -> vs_mode_menu?(gs) or at_character_select?(gs) end,
             timeout_frames,
             :rules_menu_never_reached
           ),
         # Values are counted from the fresh-session defaults, and the
         # CSS has no path back that this flow drives — a session that
         # is already past the VS menu (a second game, say) keeps the
         # rules it already has; ask for them on the FIRST play.
         :ok <- if(vs_mode_menu?(gamestate), do: :ok, else: {:error, :rules_need_fresh_menu}),
         # The helper may be mid-press when the drive stops; start the
         # edge-tap sequence from a clean controller.
         Melee.Controller.release_all(controller),
         :ok <- seek_row(session, controller, @vs_row_custom_rules),
         :ok <- menu_tap(session, controller, :a),
         :ok <- await(session, &(&1.submenu == @custom_rules_submenu), :rules_screen),
         :ok <- adjust_row(session, controller, @rules_row_stock, taps.stock),
         :ok <- set_item_rules(session, controller, taps.item_frequency, taps.item_off_cells),
         :ok <-
           set_additional_rules(session, controller, taps.time, taps.team_attack, taps.pause),
         :ok <- menu_tap(session, controller, :b),
         :ok <- await(session, &vs_mode_menu?/1, :rules_exit) do
      {:ok, helpers}
    end
  end

  # Translate the rules keyword into tap counts (negative = left) from
  # the fresh-session defaults, raising on out-of-range values. Team
  # Attack and Pause default ON, so only `false` needs a tap.
  defp rules_taps!(rules) do
    %{
      stock: counted_taps!(rules, :stock, @default_stock),
      time: counted_taps!(rules, :time_limit, @default_time_limit_min),
      team_attack: if(Keyword.get(rules, :team_attack, true), do: 0, else: 1),
      pause: if(Keyword.get(rules, :pause, true), do: 0, else: 1),
      item_frequency: item_frequency_taps!(rules),
      item_off_cells: item_off_cells!(rules)
    }
  end

  defp counted_taps!(rules, key, default) do
    case Keyword.get(rules, key) do
      nil ->
        0

      n when n in 1..99 ->
        n - default

      other ->
        raise ArgumentError, "rules: #{inspect(key)} must be 1..99, got #{inspect(other)}"
    end
  end

  defp item_frequency_taps!(rules) do
    case Keyword.get(rules, :item_frequency) do
      nil ->
        0

      frequency when is_map_key(@item_frequency_taps, frequency) ->
        @item_frequency_taps[frequency]

      other ->
        raise ArgumentError,
              "rules: :item_frequency must be one of " <>
                "#{inspect(Map.keys(@item_frequency_taps))}, got #{inspect(other)}"
    end
  end

  defp item_off_cells!(rules) do
    case Keyword.get(rules, :items) do
      nil ->
        []

      items when is_list(items) ->
        keep =
          MapSet.new(items, fn item ->
            id = resolve!(Enums.ProjectileType, item)

            Map.get(@item_cell_by_id, id) ||
              raise ArgumentError,
                    "rules: :items entry #{inspect(item)} is not a switchable item"
          end)

        for cell <- Map.values(@item_cell_by_id), cell not in keep, do: cell

      other ->
        raise ArgumentError, "rules: :items must be a list of items, got #{inspect(other)}"
    end
  end

  # The Item Switch screen (behind row 5): toggle the asked-off cells
  # walking the grid row by row (left cell, right +16, back, down —
  # only moves verified live; the columns are 16 and 15 tall), then
  # set the frequency dial below the left column. Entry is confirmed
  # the same way as Additional Rules: selection resetting to 0 under
  # submenu 0xFF.
  defp set_item_rules(_session, _controller, 0, []), do: :ok

  defp set_item_rules(session, controller, frequency_taps, off_cells) do
    with :ok <- seek_row(session, controller, @rules_row_items),
         :ok <- menu_tap(session, controller, :a),
         :ok <- await(session, &(&1.menu_selection == 0), :item_switch_screen),
         :ok <- toggle_item_cells(session, controller, off_cells),
         :ok <- set_item_frequency(session, controller, frequency_taps),
         :ok <- menu_tap(session, controller, :b) do
      await(session, &(&1.submenu == @custom_rules_submenu), :item_switch_exit)
    end
  end

  defp toggle_item_cells(_session, _controller, []), do: :ok

  defp toggle_item_cells(session, controller, off_cells) do
    off = MapSet.new(off_cells)

    tap_if_off = fn cell ->
      if cell in off, do: menu_tap(session, controller, :a), else: :ok
    end

    walk_row = fn row ->
      with :ok <- expect_selection(session, row),
           :ok <- tap_if_off.(row),
           :ok <- menu_nudge(session, controller, :right),
           :ok <- expect_selection(session, row + 16),
           :ok <- tap_if_off.(row + 16),
           :ok <- menu_nudge(session, controller, :left),
           :ok <- expect_selection(session, row) do
        menu_nudge(session, controller, :down)
      end
    end

    with :ok <-
           Enum.reduce_while(0..14, :ok, fn row, :ok ->
             case walk_row.(row) do
               :ok -> {:cont, :ok}
               error -> {:halt, error}
             end
           end),
         :ok <- expect_selection(session, 15) do
      tap_if_off.(15)
    end
  end

  defp set_item_frequency(_session, _controller, 0), do: :ok

  defp set_item_frequency(session, controller, taps) do
    with :ok <- seek_row(session, controller, @item_switch_frequency_row, 20) do
      adjust_row(session, controller, @item_switch_frequency_row, taps)
    end
  end

  defp expect_selection(session, want) do
    case step_frame(session) do
      {:ok, %GameState{menu_selection: ^want}} -> :ok
      {:ok, gamestate} -> {:error, {:rules_grid_lost, want, gamestate.menu_selection}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Additional Rules (behind row 6): Stock Time Limit row 0, Team
  # Attack row 1, Pause row 2. Entering it is only observable as
  # menu_selection resetting to 0 under submenu 0xFF, so the entry is
  # confirmed by awaiting selection 0 after the A press.
  defp set_additional_rules(_session, _controller, 0, 0, 0), do: :ok

  defp set_additional_rules(session, controller, time_taps, team_attack_taps, pause_taps) do
    with :ok <- seek_row(session, controller, @rules_row_additional),
         :ok <- menu_tap(session, controller, :a),
         :ok <- await(session, &(&1.menu_selection == 0), :additional_rules_screen),
         :ok <- adjust_row(session, controller, @additional_row_time_limit, time_taps),
         :ok <- adjust_row(session, controller, @additional_row_team_attack, team_attack_taps),
         :ok <- adjust_row(session, controller, @additional_row_pause, pause_taps),
         :ok <- menu_tap(session, controller, :b) do
      await(session, &(&1.submenu == @custom_rules_submenu), :additional_rules_exit)
    end
  end

  defp vs_mode_menu?(%GameState{menu_state: @main_menu, submenu: @vs_mode_submenu}), do: true
  defp vs_mode_menu?(%GameState{}), do: false

  defp adjust_row(_session, _controller, _row, 0), do: :ok

  defp adjust_row(session, controller, row, taps) do
    dir = if taps > 0, do: :right, else: :left

    with :ok <- seek_row(session, controller, row) do
      Enum.reduce_while(1..abs(taps), :ok, fn _i, :ok ->
        case menu_nudge(session, controller, dir) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # Down-nudge until menu_selection reads `row` (every rules list
  # wraps, so down-only reaches any row from any row).
  defp seek_row(session, controller, row, attempts \\ 10)

  defp seek_row(_session, _controller, row, 0), do: {:error, {:rules_row_never_reached, row}}

  defp seek_row(session, controller, row, attempts) do
    case step_frame(session) do
      {:ok, %GameState{menu_selection: ^row}} ->
        :ok

      {:ok, _gamestate} ->
        with :ok <- menu_nudge(session, controller, :down),
             do: seek_row(session, controller, row, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp menu_nudge(session, controller, dir) do
    {x, y} =
      case dir do
        :down -> {0.5, 0.0}
        :left -> {0.0, 0.5}
        :right -> {1.0, 0.5}
      end

    with :ok <-
           input_frames(session, 2, fn ->
             Melee.Controller.tilt_analog(controller, :main, x, y)
           end) do
      input_frames(session, 10, fn -> Melee.Controller.release_all(controller) end)
    end
  end

  defp menu_tap(session, controller, button) do
    with :ok <-
           input_frames(session, 2, fn -> Melee.Controller.press_button(controller, button) end) do
      input_frames(session, 10, fn -> Melee.Controller.release_button(controller, button) end)
    end
  end

  defp input_frames(_session, 0, _input), do: :ok

  defp input_frames(session, frames, input) do
    input.()

    case Session.step(session) do
      {:error, reason} -> {:error, reason}
      _frame_or_nil -> input_frames(session, frames - 1, input)
    end
  end

  @rules_await_frames 300

  defp await(session, done?, why, frames_left \\ @rules_await_frames)

  defp await(_session, _done?, why, 0), do: {:error, {:rules_timeout, why}}

  defp await(session, done?, why, frames_left) do
    case step_frame(session) do
      {:ok, gamestate} ->
        if done?.(gamestate), do: :ok, else: await(session, done?, why, frames_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One step that always yields a gamestate: a polling console can hand
  # back nil, and the menus stream every frame, so nil just means "ask
  # again".
  defp step_frame(session) do
    case Session.step(session) do
      {:ok, gamestate} -> {:ok, gamestate}
      nil -> step_frame(session)
      {:error, reason} -> {:error, reason}
    end
  end

  # The Team Battle flow, phased: every cross-hand action needs an
  # EMPTY hand (a held token gets placed instead of pressing) and a
  # settled press, so the picks must fully land (coins DOWN, not just
  # hovered) before the mode toggle and the color chips are touched.
  defp play_teams(session, [{leader, _} | _] = specs, controllers, helpers, timeout_frames) do
    with {:ok, helpers, _gs} <-
           drive_until(
             session,
             specs,
             controllers,
             helpers,
             fn gs -> Enum.all?(specs, &coin_placed?(gs, &1)) end,
             timeout_frames,
             :teams_picks_never_landed
           ),
         {tx, ty} = @teams_toggle,
         {:ok, _} <- Cursor.goto(session, controllers[leader], leader, tx, ty),
         {:ok, _} <- Cursor.settled_tap(session, controllers[leader], :a),
         :ok <- set_team_colors(session, specs, controllers),
         # All ports default RED, so ready_to_start doubles as the
         # "teams are valid" signal — if the asked-for colors cannot
         # form two teams, this times out rather than hanging later.
         {:ok, helpers, _gs} <-
           drive_until(
             session,
             specs,
             controllers,
             helpers,
             & &1.ready_to_start,
             timeout_frames,
             :teams_never_ready
           ) do
      loop(session, specs, controllers, helpers, timeout_frames)
    end
  end

  defp coin_placed?(gamestate, {port, spec}) do
    case Map.get(gamestate.players || %{}, port) do
      nil ->
        false

      player ->
        character_ok? = player.character == Keyword.fetch!(spec, :character)

        case Keyword.get(spec, :cpu_level) do
          nil -> character_ok? and player.coin_down
          level -> character_ok? and player.cpu_level == level
        end
    end
  end

  defp set_team_colors(session, specs, controllers) do
    Enum.reduce_while(specs, :ok, fn {port, spec}, :ok ->
      taps = spec |> Keyword.get(:team, :red) |> Enums.Team.to_id()

      with true <- taps > 0,
           x = @team_chip_x + @panel_spacing * (port - 1),
           {:ok, _} <- Cursor.goto(session, controllers[port], port, x, @team_chip_y),
           :ok <- tap_chip(session, controllers[port], taps) do
        {:cont, :ok}
      else
        false -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:team_color, port, reason}}}
      end
    end)
  end

  defp tap_chip(session, controller, taps) do
    Enum.reduce_while(1..taps, :ok, fn _i, :ok ->
      case Cursor.settled_tap(session, controller, :a) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Drive the menu helpers (autostart withheld) until `done?` holds on
  # the gamestate.
  defp drive_until(_session, _specs, _controllers, _helpers, _done?, 0, why),
    do: {:error, why}

  defp drive_until(session, specs, controllers, helpers, done?, frames_left, why) do
    case Session.step(session) do
      {:ok, gamestate} ->
        if done?.(gamestate) do
          {:ok, helpers, gamestate}
        else
          helpers = drive_ports(gamestate, specs, controllers, helpers, false)
          drive_until(session, specs, controllers, helpers, done?, frames_left - 1, why)
        end

      nil ->
        drive_until(session, specs, controllers, helpers, done?, frames_left, why)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp loop(_session, _specs, _controllers, _helpers, 0), do: {:error, :timeout}

  defp loop(session, specs, controllers, helpers, frames_left) do
    case Session.step(session) do
      {:ok, gamestate} ->
        if GameState.in_game?(gamestate) do
          {:ok, gamestate}
        else
          helpers = drive_ports(gamestate, specs, controllers, helpers, true)
          loop(session, specs, controllers, helpers, frames_left - 1)
        end

      nil ->
        # Polling console with no frame ready: keep waiting, this does
        # not consume the frame budget.
        loop(session, specs, controllers, helpers, frames_left)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp drive_ports(gamestate, [{leader, _} | _] = specs, controllers, helpers, autostart?) do
    others = for {gc_port, spec} <- specs, gc_port != leader, do: spec

    Map.new(specs, fn {gc_port, spec} ->
      helper_opts =
        if gc_port == leader,
          do: leader_opts(spec, gamestate, others, autostart?),
          else: spec

      helper = MenuHelper.step(helpers[gc_port], gamestate, controllers[gc_port], helper_opts)
      {gc_port, helper}
    end)
  end

  # The leader's cross-port gates. Both only bite AT the CSS — past it
  # the gamestate stops reporting the fields the gates read, and
  # MenuHelper needs :autostart to navigate the stage select at all.
  # `autostart?` false (the teams setup phases) withholds START
  # entirely while still letting the picks proceed.
  defp leader_opts(spec, gamestate, others, autostart?) do
    others_ready? =
      not at_character_select?(gamestate) or
        Enum.all?(others, &port_configured?(gamestate, &1))

    spec
    |> Keyword.put(:autostart, autostart? and others_ready?)
    |> then(fn spec ->
      if others_ready?, do: spec, else: Keyword.drop(spec, [:nametag, :nametag_mode])
    end)
  end

  @doc """
  End the running game from one port with the standard LRAS quit-out
  (hold L+R+A+Start), stepping the session until the game exits.

  The fast way to end an episode: a quit-out drops straight back to
  the character select screen (no postgame scores), against ~15+
  seconds of burning stocks. Note Melee disables pausing during the
  pre-GO countdown (frames -123..-1), so a quit requested at match
  start still takes ~2.3 seconds of game time — it fires on the first
  pausable frame (measured: frame 0 exactly).

  Follows the same contract as `play/2`: returns `{:ok, gamestate}`
  with the first non-in-game frame, `{:error, :timeout}` after
  `:timeout_frames` (default `400`), or the session's error.
  """
  @spec quit(GenServer.server(), GenServer.server(), keyword()) ::
          {:ok, GameState.t()} | {:error, term()}
  def quit(session, controller, opts \\ []) do
    timeout_frames = Keyword.get(opts, :timeout_frames, 400)
    result = quit_loop(session, controller, timeout_frames)
    Melee.Controller.release_all(controller)
    result
  end

  defp quit_loop(_session, _controller, 0), do: {:error, :timeout}

  defp quit_loop(session, controller, frames_left) do
    # L+R+A are held; Start is PULSED (2 on, 6 off — the cadence
    # verified live). The quit-out is edges, not a chord: a Start press
    # pauses, and the exit needs a FRESH Start edge with L+R+A down —
    # a continuous hold of all four never quits (found live: it timed
    # out), and the pulse also rides out the pre-GO pause lockout.
    Enum.each([:l, :r, :a], &Melee.Controller.press_button(controller, &1))

    if rem(frames_left, 8) in [0, 1],
      do: Melee.Controller.press_button(controller, :start),
      else: Melee.Controller.release_button(controller, :start)

    case Session.step(session) do
      {:ok, gamestate} ->
        if GameState.in_game?(gamestate),
          do: quit_loop(session, controller, frames_left - 1),
          else: {:ok, gamestate}

      nil ->
        # A PAUSED game emits no spectator frames, so nil steps are the
        # normal state mid-quit — and the pulse is keyed on frames_left,
        # so nil MUST consume budget too. A version that didn't
        # deadlocked: silence began during the pulse's release phase,
        # the frozen counter held Start released forever, and the pause
        # never resolved.
        quit_loop(session, controller, frames_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Has this port finished configuring at the CSS — the right character
  locked in, plus level and CPU status when a `:cpu_level` was asked
  for?

  Deliberately ignores `coin_down` ("hand is on the coin right now",
  not "has picked" — gating on it deadlocks; see `docs/melee-menus.md`).
  """
  @spec port_configured?(GameState.t(), keyword()) :: boolean()
  def port_configured?(%GameState{} = gamestate, spec) do
    port = Keyword.fetch!(spec, :port)

    case Map.get(gamestate.players || %{}, port) do
      nil ->
        false

      player ->
        character_ready? = player.character == Keyword.fetch!(spec, :character)

        cpu_ready? =
          case Keyword.get(spec, :cpu_level) do
            nil -> true
            level -> player.cpu_level == level and player.controller_status == @controller_cpu
          end

        character_ready? and cpu_ready?
    end
  end

  @doc "Is the gamestate at either character select screen?"
  @spec at_character_select?(GameState.t()) :: boolean()
  def at_character_select?(%GameState{menu_state: menu_state}) do
    menu_state in [
      Enums.Menu.to_id(:character_select),
      Enums.Menu.to_id(:slippi_online_css)
    ]
  end

  defp normalize_spec(spec, gc_port, stage, teams?) do
    if not teams? and Keyword.has_key?(spec, :team) do
      raise ArgumentError,
            "p#{gc_port} has a :team but the match is not teams: true"
    end

    team = Keyword.get(spec, :team, :red)

    if team not in [:red, :blue, :green] do
      raise ArgumentError, "p#{gc_port} team must be :red, :blue or :green, got #{inspect(team)}"
    end

    spec
    |> Keyword.put(:port, gc_port)
    |> Keyword.put(:stage, stage)
    |> Keyword.update!(:character, &resolve!(Enums.Character, &1))
  end

  defp resolve!(enum, value) when is_atom(value), do: enum.to_id(value)
  defp resolve!(_enum, value) when is_integer(value), do: value
end
