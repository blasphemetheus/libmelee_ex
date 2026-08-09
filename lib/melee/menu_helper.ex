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

  require Logger

  # Menu wire values (Melee.Enums.Menu)
  @character_select 0
  @stage_select 1
  @postgame_scores 4
  @main_menu 5
  @slippi_online_css 6
  @press_start 7
  @unknown_menu 0xFF

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
  Which step of the in-game nametag flow we are on.

    * `:waiting` — the starting phase: holding off until our port has
      locked a character in, because an empty CSS panel has no name box
    * `:name_box` — walking to the name box under our portrait, to open
      the tag list
    * `:list` — walking to a row of the open tag list (`NAME ENTRY` when
      creating, the saved-tag row when selecting)
    * `:typing` — the name-entry keyboard is up and we are spelling the
      tag out
    * `:done` — the tag is set; the flow will not run again this session
  """
  @type nametag_phase :: :waiting | :name_box | :list | :typing | :done

  @typedoc """
  Menu-navigation state. Mirrors the Python instance attributes:
  connect-code entry progress (`name_tag_index`, `inputs_live`) and
  stage-select progress (`frames_on_stage`, `frozen_stadium_selected`,
  `stage_selected`), plus two things with no Python counterpart: the
  in-game nametag flow (`nametag_phase`, `nametag_frames`,
  `nametag_done`) and unknown-scene recovery (`seen_known_menu`, which
  retires pressing A at nameless scenes once a real menu is reached, and
  `unknown_frames`, how long the current nameless scene has persisted).
  """
  # Menu watchdog: how many frames of zero progress before stuck?/2
  # trips and :on_stuck fires. 30s at 60fps — long enough that netplay
  # matchmaking waits and a human dawdling at a shared CSS don't trip it
  # under the default; sessions that drive every menu themselves
  # (autostart evals) can pass a much tighter :stuck_after_frames.
  @stuck_after_frames_default 1800

  # Slippi Online CSS: frames of failed DIRECT portrait selection before
  # falling back to the ported random-reroll behavior (park on RANDOM,
  # re-roll until the wanted character comes up — a 1-in-26 slot machine,
  # ~40 presses observed live 2026-08-09). Direct steering is the
  # default; the reroll survives only as layout-drift insurance.
  @slippi_direct_fallback_frames 600

  @type t :: %__MODULE__{
          name_tag_index: non_neg_integer(),
          inputs_live: boolean(),
          frames_on_stage: non_neg_integer(),
          frozen_stadium_selected: boolean(),
          stage_selected: boolean(),
          nametag_phase: nametag_phase(),
          nametag_frames: non_neg_integer(),
          nametag_done: boolean(),
          seen_known_menu: boolean(),
          unknown_frames: non_neg_integer(),
          stall_sig: term(),
          stalled_frames: non_neg_integer(),
          stuck_reported: boolean(),
          slippi_css_frames: non_neg_integer(),
          logged_scenes: MapSet.t()
        }

  defstruct name_tag_index: 0,
            inputs_live: false,
            frames_on_stage: 0,
            frozen_stadium_selected: false,
            stage_selected: false,
            nametag_phase: :waiting,
            nametag_frames: 0,
            nametag_done: false,
            seen_known_menu: false,
            unknown_frames: 0,
            stall_sig: nil,
            stalled_frames: 0,
            stuck_reported: false,
            slippi_css_frames: 0,
            logged_scenes: nil

  @doc """
  Fresh menu-navigation state.

  ## Examples

      iex> s = Melee.MenuHelper.new()
      iex> {s.nametag_phase, s.stalled_frames, s.slippi_css_frames}
      {:waiting, 0, 0}
      iex> MapSet.size(s.logged_scenes)
      0
  """
  @spec new() :: t()
  def new, do: %__MODULE__{logged_scenes: MapSet.new()}

  @doc """
  Has the menu watchdog tripped? True once `step/4` has seen no menu
  progress for `:stuck_after_frames` consecutive frames (default
  #{1800} = 30s at 60fps). See the `:on_stuck` option of `step/4`.
  """
  @spec stuck?(t(), keyword()) :: boolean()
  def stuck?(%__MODULE__{stalled_frames: frames}, opts \\ []) do
    frames >= Keyword.get(opts, :stuck_after_frames, @stuck_after_frames_default)
  end

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
    * `:nametag` — in-game Melee nametag (max 4 characters, e.g.
      `"EXPH"`) to put on our port, or `nil` (default) to leave the
      nametag alone. When set, the helper drives the nametag flow at the
      CSS *before* picking a character, once per helper (tracked by
      `nametag_done`). Recorded in the replay's GAME_START event, so a
      bot's games are identifiable — see `Melee.PlayerState.nametag`.
    * `:nametag_mode` — `:select` (default) picks an already-saved tag
      out of the tag list; `:create` drives NAME ENTRY and spells the
      tag out on the keyboard. Creating needs a writable memory card and
      would pile up duplicate tags if it ran every game, so the intended
      workflow is `:create` once, `:select` from then on.
    * `:unknown_scene` — `:recover` (default) gets us off scenes the
      spectator stream cannot name, which otherwise hang a session
      forever: Melee's "Create Game Data?" memory-card prompt at boot
      (answered with A) and the Slippi log-in screen a never-logged-in
      user directory boots straight into (backed out of with B). It
      tries A briefly, then falls back to B, and never presses A once a
      real menu has been seen. `:ignore` leaves such scenes alone.
    * `:user_json?` — whether Dolphin's user directory has a
      `user.json`. Defaults to `true` (assume it does), which keeps
      every existing caller working. Pass
      `user_json?: dolphin.user_json?` — `Melee.Dolphin` reports it —
      and a `:connect_code` without one raises `ArgumentError` at the
      call instead of silently sitting on the online menu, matching
      upstream's `ValueError("Can't enter a connect code without a
      user.json configured.")`. An empty connect code is exempt, as it
      is in Python (`""` is falsey there).
    * `:stuck_after_frames` — menu-watchdog threshold (default `1800`,
      30s): frames of zero menu progress (same scene, no cursor/phase/
      selection movement on any port) before the state counts as stuck.
      A wedged session used to sit silently at a screen until some
      external timeout killed it (observed 2026-08-09: a login-screen
      wedge burned 9 minutes); the watchdog turns that into a readable
      signal in seconds. Progress in-game resets it. Query with
      `stuck?/2`.
    * `:on_stuck` — 1-arity fun invoked ONCE per stall episode when the
      threshold is crossed, with `%{menu_state: ..., frames: ...}`.
      Fire a log line, send a message to your session owner — whatever
      turns the silence into an event. `nil` (default) disables the
      callback (the `stuck?/2` flag still works).

  The nametag support and the unknown-scene recovery have no Python
  libmelee counterpart; the cursor coordinates they use were measured
  empirically (see the module source).

  ## Examples

      iex> Melee.MenuHelper.step(
      ...>   Melee.MenuHelper.new(), %Melee.GameState{menu_state: 0}, self(),
      ...>   character: 0x01, stage: 0x19, connect_code: "EXPH#288", user_json?: false)
      ** (ArgumentError) can't enter a connect code without a user.json configured
  """
  @spec step(t(), GameState.t(), GenServer.server(), keyword()) :: t()
  def step(%__MODULE__{} = state, %GameState{} = gamestate, controller, opts) do
    character = Keyword.fetch!(opts, :character)
    stage = Keyword.fetch!(opts, :stage)
    connect_code = Keyword.get(opts, :connect_code, nil)
    check_user_json!(connect_code, Keyword.get(opts, :user_json?, true))
    cpu_level = Keyword.get(opts, :cpu_level, 0)
    costume = Keyword.get(opts, :costume, 0)
    autostart = Keyword.get(opts, :autostart, false)
    swag = Keyword.get(opts, :swag, false)
    frozen_stadium = Keyword.get(opts, :frozen_stadium, true)
    port = Keyword.get(opts, :port, 1)
    nametag = Keyword.get(opts, :nametag, nil)
    nametag_mode = Keyword.get(opts, :nametag_mode, :select)
    unknown_scene = Keyword.get(opts, :unknown_scene, :recover)

    # Reaching any menu we recognize retires boot-dialog handling.
    state = note_known_menu(state, gamestate)

    result = cond do
      gamestate.menu_state in [@character_select, @slippi_online_css] ->
        cond do
          nametag_pending?(state, gamestate, nametag, port) ->
            set_nametag(state, gamestate, controller, nametag, nametag_mode, port)

          # Only claim the name-entry screen when we actually mean to type
          # a connect code (v0.47 semantics: nil = leave it to a human).
          #
          # The `connect_code != nil` half is load-bearing, not just an
          # optimisation. Melee leaves `submenu` reading
          # @name_entry_submenu after the keyboard closes — the nametag
          # flow has to finish on a frame count for exactly this reason —
          # so `name_entry?/1` keeps saying "yes" back at the CSS. Taking
          # this branch on that stale value stranded the port: it never
          # picked a character and never pressed START, leaving the match
          # sat on READY TO FIGHT forever.
          connect_code != nil and name_entry?(gamestate) ->
            enter_direct_code(state, gamestate, controller, connect_code)

          true ->
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

      # A scene the spectator stream cannot name. Melee's boot-time
      # memory-card prompt and the Slippi log-in screen both land here.
      unknown_scene == :recover and gamestate.menu_state == @unknown_menu ->
        recover_unknown_scene(state, gamestate, controller)

      # In-game (or an unknown scene we've decided not to touch)
      true ->
        state
    end

    track_progress(result, gamestate, opts)
  end

  ## Menu watchdog

  # Advance or reset the stall counter, and fire :on_stuck exactly once
  # per stall episode when the threshold is crossed.
  defp track_progress(state, gamestate, opts) do
    if GameState.in_game?(gamestate) do
      %{state | stall_sig: nil, stalled_frames: 0, stuck_reported: false}
    else
      sig = progress_sig(state, gamestate)

      if sig == state.stall_sig do
        state = %{state | stalled_frames: state.stalled_frames + 1}
        threshold = Keyword.get(opts, :stuck_after_frames, @stuck_after_frames_default)
        on_stuck = Keyword.get(opts, :on_stuck)

        if on_stuck && state.stalled_frames >= threshold && not state.stuck_reported do
          on_stuck.(%{menu_state: gamestate.menu_state, frames: state.stalled_frames})
          %{state | stuck_reported: true}
        else
          state
        end
      else
        %{state | stall_sig: sig, stalled_frames: 0, stuck_reported: false}
      end
    end
  end

  # What "progress" means at a menu: the scene itself, every port's
  # cursor (quantized to half units — the CSS hand jitters sub-pixel),
  # hovered character / CPU level / coin state, and our own flow phases.
  # Any of these moving means the session is going somewhere.
  defp progress_sig(state, gamestate) do
    players =
      for {port, player} <- Enum.sort(gamestate.players || %{}), player != nil do
        cursor =
          case player.cursor do
            %{x: x, y: y} when is_number(x) and is_number(y) -> {round(x * 2), round(y * 2)}
            _ -> nil
          end

        {port, cursor, player.character, player.cpu_level, player.coin_down}
      end

    {gamestate.menu_state, gamestate.submenu, players, state.nametag_phase,
     state.name_tag_index, state.stage_selected, state.frames_on_stage > 0}
  end

  # Upstream raises from menu_helper_simple when a connect code is asked
  # for on a console with no user.json, because Dolphin simply cannot
  # log in and the direct-match flow would never complete. We can't read
  # that off a Controller (Python reaches through `controller._console`),
  # so the caller passes it; defaulting to `true` keeps the check
  # strictly opt-in and never crashes a session that didn't ask for it.
  defp check_user_json!(connect_code, false)
       when is_binary(connect_code) and connect_code != "" do
    raise ArgumentError, "can't enter a connect code without a user.json configured"
  end

  defp check_user_json!(_connect_code, _user_json?), do: :ok

  ## Unknown scenes (boot dialogs, the Slippi log-in screen)

  # Scenes the spectator stream has no name for all arrive as
  # @unknown_menu with no players, and without help the session simply
  # sits on them forever. Two show up in practice, and they want
  # opposite answers:
  #
  #   * With a memory card plugged in but no Melee save on it, the game
  #     opens "The Memory Card in Slot A has no saved Game Data. Create
  #     Game Data?" (Yes preselected) and then an acknowledgement. Both
  #     are dismissed with A.
  #   * A Dolphin whose user directory has never logged in to Slippi
  #     boots straight into Online Play's log-in screen. A does nothing
  #     useful there; B backs out to a menu we understand.
  #
  # So: try A for a while, and if the scene is still unknown after
  # @unknown_accept_frames, back out with B instead. A dialog answers
  # within a frame or two and the scene changes; a screen that ignores A
  # eventually gets the B it wanted. Once any real menu has been seen we
  # never press A at an unknown scene again — mid-session, backing out is
  # the only safe move.
  @unknown_accept_frames 300

  defp recover_unknown_scene(state, gamestate, controller) do
    # Log each distinct unknown raw scene ONCE — turns "we're stuck on
    # some nameless screen" into "raw scene 0xNNNN, still unrecognized",
    # the datum needed to give it a named clause in Events.Menu. This is
    # how the login/boot scenes stop being blind spots.
    scene = gamestate.raw_scene
    state = maybe_log_unknown_scene(state, scene)

    button =
      if not state.seen_known_menu and state.unknown_frames < @unknown_accept_frames,
        do: :a,
        else: :b

    # Pulse rather than hold: holding would answer only the first prompt.
    if Integer.mod(gamestate.frame, 2) == 0 do
      Controller.release_button(controller, button)
    else
      Controller.press_button(controller, button)
    end

    %{state | unknown_frames: state.unknown_frames + 1}
  end

  defp maybe_log_unknown_scene(state, scene) do
    seen = state.logged_scenes || MapSet.new()
    state = %{state | logged_scenes: seen}

    if scene == nil or MapSet.member?(seen, scene) do
      state
    else
      Logger.info(
        "[MenuHelper] unrecognized menu scene #{inspect(scene, base: :hex)} " <>
          "(#{inspect(Melee.Events.Menu.scene_name(scene))}) — recovering blind. " <>
          "Add a named clause in Melee.Events.Menu to type it."
      )

      %{state | logged_scenes: MapSet.put(state.logged_scenes, scene)}
    end
  end

  # Latch "we have seen a real menu", which retires pressing A at unknown
  # scenes, and reset the stuck-scene counter.
  defp note_known_menu(state, %GameState{menu_state: @unknown_menu}), do: state

  defp note_known_menu(state, _gamestate) do
    %{state | seen_known_menu: true, unknown_frames: 0}
  end

  ## In-game nametag (Melee save data)

  # Cursor coordinates below were MEASURED EMPIRICALLY against a real
  # Dolphin (netplay-stable Slippi build, VS-mode CSS, port 1). None of
  # this is readable from the gamestate, so the flow is coordinate- and
  # frame-count-driven rather than feedback-driven.

  # The name box under our character portrait; pressing A here opens the
  # port's tag list. Measured for port 1; panels are @panel_spacing apart
  # in x, the same spacing the CPU/HMN box uses in configure_cpu.
  # Presses at x = -23.56, -23.22 and -22.94 all opened the list; ones at
  # -22.73 and -22.32 did not. The hand arrives from the character
  # portrait on the right, so we aim left of centre to land safely.
  @nametag_box_x -23.7
  @nametag_box_y -18.62
  @panel_spacing 15.82

  # y of the SECOND row of the open tag list. Only y matters: the open
  # list pins the hand's x wherever the list was opened from, so we never
  # steer x here.
  #
  # The list reads: row 1 = the current name, then one row per saved tag,
  # and "NAME ENTRY" always LAST. So row 2 is exactly the row each mode
  # wants — NAME ENTRY when no tag is saved yet (`:create`), and the one
  # saved tag once there is one (`:select`). This is why the create-once,
  # select-thereafter workflow needs a single coordinate.
  #
  # Measured: with no saved tags, presses at y = -9.66, -9.04, -8.58 and
  # -7.78 all landed on NAME ENTRY (x ranging from -29.5 to -25.2). After
  # saving one tag, NAME ENTRY had moved down to y = -11.1, which puts
  # the row pitch at about 2.4.
  @nametag_row2_y -8.7

  # Tolerance for "the hand is on this row/box". Narrower than the
  # character-portrait wiggleroom of 1.5, because a list row is small.
  @nametag_tolerance 0.6

  # The name box needs its own: it is the one target we approach in x, so
  # the band must be tight enough to actually pull the hand left off the
  # portrait, and narrow enough to stay inside the box.
  @nametag_box_tolerance 0.4

  # menu_selection of the keyboard's CONFIRM button ("Register this
  # name."), which START jumps to and A activates.
  @confirm_selection 57

  # A is pulsed by holding it for @nametag_press_frames and then letting
  # go for the rest of @nametag_settle_frames, so the menu sees exactly
  # one press and has time to open before we look again.
  @nametag_press_frames 4
  @nametag_settle_frames 24

  # An empty CSS panel has no name box to open, so the flow can only
  # start once our port has actually locked a character in.
  @no_character 0xFF

  # Is there a nametag left to set? Nil opts and a finished flow both
  # mean "no", which keeps every existing caller on the old code path.
  # We also hold off in the `:waiting` phase until choose_character/9 has
  # locked a character onto our panel — the name box (and hence the tag
  # list) does not exist before then. Leaving `:waiting` latches the flow
  # on, so it cannot hand control back mid-walk.
  defp nametag_pending?(state, gamestate, nametag, port) do
    nametag != nil and not state.nametag_done and
      (state.nametag_phase != :waiting or character_locked_in?(gamestate, port))
  end

  # `character` alone is NOT enough: at the CSS it reports whichever
  # portrait the hand is *hovering*, so it flickers between a real id and
  # 0xFF as the cursor crosses the grid. `coin_down` — the port's token
  # actually sitting on a portrait — is what says the pick is locked in.
  defp character_locked_in?(gamestate, port) do
    case Map.fetch(gamestate.players, port) do
      {:ok, player} -> player.coin_down and player.character != @no_character
      :error -> false
    end
  end

  # One frame of the nametag flow: walk to the name box, open the tag
  # list, then either pick the saved tag (`:select`) or walk to NAME
  # ENTRY and spell the tag out on the keyboard (`:create`).
  defp set_nametag(state, gamestate, controller, nametag, mode, port) do
    # First frame we get control: latch the flow on, so a `character`
    # that flickers back to 0xFF cannot hand us back to choose_character.
    state =
      if state.nametag_phase == :waiting,
        do: %{state | nametag_phase: :name_box},
        else: state

    cond do
      # The keyboard is up: same screen enter_direct_code/4 drives.
      name_entry?(gamestate) ->
        state =
          if state.nametag_phase == :typing,
            do: state,
            else: %{state | nametag_phase: :typing, nametag_frames: 0}

        type_nametag(state, gamestate, controller, nametag)

      # We were typing and the keyboard is gone, so the tag was
      # confirmed and is now selected on our port.
      state.nametag_phase == :typing ->
        Controller.release_all(controller)
        %{state | nametag_phase: :done, nametag_done: true}

      state.nametag_phase == :name_box ->
        open_tag_list(state, gamestate, controller, port)

      state.nametag_phase == :list ->
        pick_tag_row(state, gamestate, controller, mode, port)

      true ->
        Controller.release_all(controller)
        %{state | nametag_done: true}
    end
  end

  # Walk the hand onto the name box and press A to open the tag list.
  defp open_tag_list(state, gamestate, controller, port) do
    target_x = @nametag_box_x + @panel_spacing * (port - 1)

    press_at(
      state,
      gamestate,
      controller,
      port,
      target_x,
      @nametag_box_y,
      @nametag_box_tolerance,
      fn state -> %{state | nametag_phase: :list, nametag_frames: 0} end
    )
  end

  # Walk the hand onto the open tag list's second row and press A: NAME
  # ENTRY when creating (no tags saved yet), the saved tag when selecting
  # (see @nametag_row2_y). `nil` for x because the open list pins it —
  # only y chooses the row.
  defp pick_tag_row(state, gamestate, controller, mode, port) do
    press_at(
      state,
      gamestate,
      controller,
      port,
      nil,
      @nametag_row2_y,
      @nametag_tolerance,
      fn state ->
        case mode do
          # Creating: if that A opened the keyboard, set_nametag/6 notices
          # on the very next frame via name_entry?/1 and we never come back
          # here. If it did not, the list must not have been open, so start
          # the whole flow over rather than jabbing A at a dead row — there
          # is no gamestate field that tells us the list is up.
          :create -> %{state | nametag_phase: :name_box, nametag_frames: 0}
          :select -> %{state | nametag_phase: :done, nametag_done: true}
        end
      end
    )
  end

  # Shared "get the hand to (target_x, target_y), pulse A once, then run
  # `on_pressed`" step. Returns the updated state.
  defp press_at(state, gamestate, controller, port, target_x, target_y, tolerance, on_pressed) do
    # Once the press has started we stop steering and just run the counter
    # out. Opening the tag list yanks the hand off the name box (Melee
    # pins it to the list's own column), so re-checking arrival here would
    # see `:moving`, zero the counter, and never finish.
    if state.nametag_frames > 0 do
      run_out_press(state, controller, on_pressed)
    else
      steer_and_press(state, gamestate, controller, port, target_x, target_y, tolerance)
    end
  end

  # Walk toward the target; the frame we arrive, start the A press.
  defp steer_and_press(state, gamestate, controller, port, target_x, target_y, tolerance) do
    case Map.fetch(gamestate.players, port) do
      {:ok, player} ->
        case move_toward(controller, player.cursor, target_x, target_y, tolerance) do
          :moving ->
            Controller.release_button(controller, :a)
            state

          :arrived ->
            Controller.press_button(controller, :a)
            %{state | nametag_frames: 1}
        end

      :error ->
        Controller.release_all(controller)
        state
    end
  end

  # Hold A for @nametag_press_frames, let go for the rest of
  # @nametag_settle_frames so the menu has time to react, then hand off.
  defp run_out_press(state, controller, on_pressed) do
    frames = state.nametag_frames

    cond do
      frames < @nametag_press_frames ->
        Controller.press_button(controller, :a)
        %{state | nametag_frames: frames + 1}

      frames < @nametag_settle_frames ->
        Controller.release_button(controller, :a)
        %{state | nametag_frames: frames + 1}

      true ->
        Controller.release_button(controller, :a)
        on_pressed.(state)
    end
  end

  # Distance at which we ease off the stick. The CSS cursor accelerates
  # while the stick is pinned, so a full tilt aimed at a target barely
  # two units across sails straight past it; a gentle tilt inside
  # @nametag_fine units creeps onto it at roughly 0.2 units a frame,
  # which lands inside the tolerances below. Measured against Dolphin.
  @nametag_fine 3.0
  @nametag_fine_tilt 0.22

  # Tilt the main stick toward (target_x, target_y). Returns `:moving`
  # while outside `tolerance` and `:arrived` (stick centered) once inside.
  #
  # `target_x` may be `nil` for "don't steer x at all": while the tag
  # list is open Melee pins the hand to the list's column, so x cannot be
  # moved (measured: even a full tilt leaves it put) and only y picks the
  # row.
  @spec move_toward(
          GenServer.server(),
          Melee.Position.t(),
          number() | nil,
          number(),
          number()
        ) :: :moving | :arrived
  defp move_toward(controller, %{y: cursor_y}, nil, target_y, tolerance) do
    cond do
      cursor_y < target_y - tolerance ->
        Controller.tilt_analog(controller, :main, 0.5, 0.5 + tilt(target_y - cursor_y))
        :moving

      cursor_y > target_y + tolerance ->
        Controller.tilt_analog(controller, :main, 0.5, 0.5 - tilt(cursor_y - target_y))
        :moving

      true ->
        Controller.tilt_analog(controller, :main, 0.5, 0.5)
        :arrived
    end
  end

  defp move_toward(controller, cursor, target_x, target_y, tolerance) do
    steer_toward(controller, cursor, target_x, target_y, tolerance)
  end

  # Proportional 2D steering: tilt the stick along the error VECTOR so
  # the hand travels the direct diagonal path, instead of the
  # axis-at-a-time bang-bang the Python helper traces (y first, then x —
  # the "hand goes up, then over" L every menu pick used to draw).
  #
  # An axis already inside `tolerance` contributes nothing, so the tail
  # of the approach degrades gracefully to single-axis steering — which
  # also keeps the active component at full magnitude, safely outside
  # the analog deadzone (the 0.15-tilt-does-nothing trap the CPU slider
  # hit; see slider_tilt).
  #
  # `max_tilt` caps how far off center the stick goes (default 0.5 =
  # full). The ease-off inside @nametag_fine units is the measured CSS
  # rule: the cursor accelerates while the stick is pinned, so full tilt
  # aimed at a near target sails past it.
  @spec steer_toward(
          GenServer.server(),
          Melee.Position.t(),
          number(),
          number(),
          number(),
          keyword()
        ) :: :moving | :arrived
  defp steer_toward(controller, %{x: cursor_x, y: cursor_y}, target_x, target_y, tolerance, opts \\ []) do
    max_tilt = Keyword.get(opts, :max_tilt, 0.5)

    dx = if abs(target_x - cursor_x) <= tolerance, do: 0.0, else: target_x - cursor_x
    dy = if abs(target_y - cursor_y) <= tolerance, do: 0.0, else: target_y - cursor_y

    if dx == 0.0 and dy == 0.0 do
      Controller.tilt_analog(controller, :main, 0.5, 0.5)
      :arrived
    else
      # Chebyshev normalization (divide by the DOMINANT axis, not the
      # euclidean distance): the dominant component always carries the
      # full magnitude. Euclidean split the 0.22 fine tilt into ~0.156
      # per axis on diagonals — inside the analog deadzone (0.15 moves
      # nothing; see slider_tilt) — freezing the hand just outside
      # tolerance forever. Live failure 2026-08-09: 3 of 4 pool-eval
      # sessions sat at stage select ~170k frames until an external
      # deadline killed them.
      dist = :math.sqrt(dx * dx + dy * dy)
      scale = max(abs(dx), abs(dy))
      mag = min(tilt(dist), max_tilt)
      Controller.tilt_analog(controller, :main, 0.5 + mag * dx / scale, 0.5 + mag * dy / scale)
      :moving
    end
  end

  # How far off center to push the stick, given how far we still have to
  # travel.
  defp tilt(distance) when distance > @nametag_fine, do: 0.5
  defp tilt(_distance), do: @nametag_fine_tilt

  # Spell the nametag out on the name-entry keyboard. Reuses
  # enter_direct_code/4's letter grid (it is the same screen), but
  # finishes differently: START then A on CONFIRM registers the tag,
  # where a connect code is submitted by START alone.
  defp type_nametag(state, gamestate, controller, nametag) do
    # The name entry screen is dead for the first few frames, so make
    # sure we can move off the starting letter before trusting inputs.
    state =
      if gamestate.menu_selection != 45, do: %{state | inputs_live: true}, else: state

    complete? = String.length(nametag) == state.name_tag_index

    cond do
      # The tag is spelled out and the selection is on CONFIRM: A is what
      # registers it. Melee leaves `submenu` reading @name_entry_submenu
      # even after the keyboard closes, so there is no screen change to
      # wait on — we count the press out and call the flow finished.
      complete? and gamestate.menu_selection == @confirm_selection ->
        run_out_press(state, controller, fn state ->
          %{state | nametag_phase: :done, nametag_done: true}
        end)

      not state.inputs_live ->
        Controller.tilt_analog(controller, :main, 1.0, 0.5)
        state

      # Let the controller go every other frame, as elsewhere.
      Integer.mod(gamestate.frame, 2) == 0 ->
        Controller.release_all(controller)
        state

      # Unlike a Slippi connect code, START does NOT submit here: it
      # jumps the selection to the CONFIRM button ("Register this
      # name."), handled above. Measured against Dolphin.
      complete? ->
        Controller.press_button(controller, :start)
        state

      true ->
        target_code =
          nametag
          |> String.at(state.name_tag_index)
          |> name_entry_target_code()

        do_enter_code_char(state, gamestate, controller, target_code)
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
    # An empty connect code still drives the direct-code keyboard —
    # upstream v0.47 parity ("" is falsey in Python, so their guard skips
    # it, but any code that reaches here types it). In practice "" is
    # almost always an unset env var, and it HIJACKS the keyboard from a
    # human trying to type (GOTCHA #88, 2026-08-07). Keep the behavior,
    # name the hazard — once per process, not once per frame.
    if connect_code == "" and not Process.get(:melee_warned_empty_connect_code, false) do
      Process.put(:melee_warned_empty_connect_code, true)

      Logger.warning(
        "[MenuHelper] connect_code is \"\" (empty, not nil) — driving the " <>
          "direct-code keyboard with an empty code. If a human should be " <>
          "typing here, pass connect_code: nil."
      )
    end

    # The name entry screen is dead for the first few frames
    #   So if the first character is A, then the input can get eaten
    #   Account for this by making sure we can move off the letter first
    state =
      if gamestate.menu_selection != 45, do: %{state | inputs_live: true}, else: state

    cond do
      not state.inputs_live ->
        Controller.tilt_analog(controller, :main, 1.0, 0.5)
        state

      # Release on even frames so every press-or-tilt below lands as a
      # fresh EDGE the next odd frame. Melee list menus and confirm
      # buttons act on the up->down edge (key-repeat only after a ~15f
      # hold delay), so edge-every-2-frames is the correct — and for
      # these short menus faster-than-hold — cadence, NOT an analog-hold
      # waste (cursor STEERING never neutralizes here; that path uses
      # steer_toward continuously). Investigated 2026-08-09 (hack sweep).
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
        # Direct portrait selection (2026-08-09). The ported behavior
        # forced swag=true here, which targets {row 0, col 0} — the
        # RANDOM slot — and re-rolls until the wanted character comes
        # up. Steer to the portrait like the offline CSS instead; only
        # after @slippi_direct_fallback_frames of failed direct
        # selection does the reroll kick back in.
        {Map.fetch!(gamestate.players, 1),
         state.slippi_css_frames >= @slippi_direct_fallback_frames}
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

    # Direct-selection fallback clock: counts frames spent on the online
    # CSS without the character locked; resets on success or offline.
    state =
      cond do
        not slippi_css? -> %{state | slippi_css_frames: 0}
        correct_character -> %{state | slippi_css_frames: 0}
        true -> %{state | slippi_css_frames: state.slippi_css_frames + 1}
      end

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
      # Set our CPU level correctly. Python guards this with
      # `(... and ... and ...) or is_holding_cpu_slider`, letting the
      # slider flag alone pull ANY port into the CPU state machine. We
      # additionally require `use_cpu`: on a port we are not making a CPU
      # that flag has been seen reading true anyway, and acting on it
      # strands the hand at the HMN box — the CPU machine has no idea
      # where the character portrait is, so nothing ever walks back and
      # the match can never be started.
      use_cpu and
          ((correct_character and (coin_down or cursor_y < 0) and
              cpu_level != ai_state.cpu_level) or ai_state.is_holding_cpu_slider) ->
        if slippi_css?, do: raise(ArgumentError, "CPU slider state during netplay CSS")
        configure_cpu(gamestate, controller, ai_state, port, cpu_level, use_cpu)
        state

      # Locked in on the online CSS: costume via Y, START when matched.
      # (No longer gated on swag — with direct selection swag is false
      # on the slippi CSS until the reroll fallback engages, and this
      # post-lock flow must run either way.)
      correct_character and slippi_css? ->
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

      # We are already set, so let's taunt our opponent
      correct_character and swag and opponent_state != nil and not start ->
        taunt_opponent(gamestate, controller, opponent_state, cursor_x, cursor_y)
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

  # The CPU slider sits at this height on every port, and dragging it
  # moves the cursor along x only — so a cursor that has drifted this far
  # in y is not on the slider any more, whatever the gamestate claims.
  @cpu_slider_y -15.12
  @cpu_slider_grip_y 4.0

  defp gripping_slider?(cursor_y), do: abs(cursor_y - @cpu_slider_y) <= @cpu_slider_grip_y

  # How hard to shove the CPU-level slider. Python drags at a flat 0.15
  # off centre the whole way. That is both slow — seconds to cross nine
  # levels — and, once `Melee.Controller.fix_analog_stick/1` has scaled
  # it, small enough to sit inside the stick deadzone and not move the
  # slider at all; a drag that got within two levels of its target would
  # simply stop there.
  #
  # So: slam it while there is ground to cover, and for the last couple
  # of levels use a tilt that is definitely outside the deadzone but
  # apply it every other frame. That is half speed without being
  # ignored, which lands on the level we actually asked for.
  @cpu_slider_near 2
  @cpu_slider_fine_tilt 0.3

  defp slider_tilt(levels_away, _frame) when levels_away > @cpu_slider_near, do: 0.5

  defp slider_tilt(_levels_away, frame) do
    if Integer.mod(frame, 2) == 0, do: @cpu_slider_fine_tilt, else: 0.0
  end

  # The CPU-configuration state machine: walk to the HMN/CPU box, press A,
  # walk to the slider, grab it, drag it to the wanted level, release.
  defp configure_cpu(gamestate, controller, ai_state, port, cpu_level, use_cpu) do
    %{y: cursor_y} = ai_state.cursor
    cpu_selected = ai_state.controller_status == @controller_cpu

    cond do
      # Is our controller type correct?
      cpu_selected != use_cpu ->
        wiggleroom = 1
        target_y = -2.2
        target_x = -32.2 + 15.82 * (port - 1)

        Controller.release_button(controller, :a)

        case steer_toward(controller, ai_state.cursor, target_x, target_y, wiggleroom) do
          :moving ->
            :ok

          :arrived ->
            if Integer.mod(gamestate.frame, 2) == 0 do
              Controller.press_button(controller, :a)
            else
              Controller.release_all(controller)
            end
        end

      # We think we're holding the slider, but the hand is nowhere near
      # it. Melee moves a port's cursor back to the top of its panel when
      # the CSS is interrupted — another port opening the name-entry
      # keyboard does exactly that — and `is_holding_cpu_slider` can
      # still read true afterwards. Dragging on that stale belief walks
      # the cursor off across the screen forever while the level never
      # changes, so let go and re-approach instead.
      ai_state.is_holding_cpu_slider and not gripping_slider?(cursor_y) ->
        Controller.release_all(controller)

      # Select the right CPU level on the slider
      ai_state.is_holding_cpu_slider ->
        levels_away = abs(cpu_level - ai_state.cpu_level)

        cond do
          ai_state.cpu_level > cpu_level ->
            Controller.tilt_analog(
              controller,
              :main,
              0.5 - slider_tilt(levels_away, gamestate.frame),
              0.5
            )

          ai_state.cpu_level < cpu_level ->
            Controller.tilt_analog(
              controller,
              :main,
              0.5 + slider_tilt(levels_away, gamestate.frame),
              0.5
            )

          Integer.mod(gamestate.frame, 2) == 0 ->
            Controller.press_button(controller, :a)

          true ->
            Controller.release_all(controller)
        end

      # Move over to and pick up the CPU slider. The gentler 0.3 cap is
      # the original 0.8/0.2 approach speed — grabbing the slider needs
      # finer positioning than the portrait walk.
      ai_state.cpu_level != cpu_level ->
        wiggleroom = 1
        target_y = @cpu_slider_y
        target_x = -30.9 + 15.4 * (port - 1)

        case steer_toward(controller, ai_state.cursor, target_x, target_y, wiggleroom,
               max_tilt: 0.3
             ) do
          :moving ->
            :ok

          :arrived ->
            if Integer.mod(gamestate.frame, 2) == 0 do
              Controller.press_button(controller, :a)
            else
              Controller.release_all(controller)
            end
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
          # Move in — straight line to the portrait (steer_toward), not
          # the old y-then-x L.
          Controller.release_button(controller, :a)

          case steer_toward(controller, ai_state.cursor, target_x, target_y, wiggleroom) do
            :moving ->
              :ok

            # Unreachable given over_character? is false, but Python ends
            # with an unconditional release_all here; keep it.
            :arrived ->
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
    cursor = Map.fetch!(gamestate.players, port).cursor

    case steer_toward(controller, cursor, target_x, target_y, wiggleroom) do
      :moving ->
        Controller.release_button(controller, :a)
        state

      :arrived ->
        # If we get in the right area, press A
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
      # Release on even frames so every press-or-tilt below lands as a
      # fresh EDGE the next odd frame. Melee list menus and confirm
      # buttons act on the up->down edge (key-repeat only after a ~15f
      # hold delay), so edge-every-2-frames is the correct — and for
      # these short menus faster-than-hold — cadence, NOT an analog-hold
      # waste (cursor STEERING never neutralizes here; that path uses
      # steer_toward continuously). Investigated 2026-08-09 (hack sweep).
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
      # Release on even frames so every press-or-tilt below lands as a
      # fresh EDGE the next odd frame. Melee list menus and confirm
      # buttons act on the up->down edge (key-repeat only after a ~15f
      # hold delay), so edge-every-2-frames is the correct — and for
      # these short menus faster-than-hold — cadence, NOT an analog-hold
      # waste (cursor STEERING never neutralizes here; that path uses
      # steer_toward continuously). Investigated 2026-08-09 (hack sweep).
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
