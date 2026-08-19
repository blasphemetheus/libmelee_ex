defmodule Melee.GameEvents do
  @moduledoc """
  Semantic gameplay events derived from consecutive `Melee.GameState`s.

  `Melee.Events` decodes the wire; this module answers "what just
  *happened*": games starting and ending, stocks falling (and whether the
  death was a self-destruct or a KO), shields breaking, menus changing.
  A live session can score itself from these instead of re-parsing the
  replay afterwards — the post-hoc behavior analysis ExPhil ran on
  2026-08-09 (stocks / SD-vs-KO / shield breaks per eval run) becomes a
  fold over this stream.

  Pure and allocation-light: feed every gamestate through `step/2`, get
  back `{events, tracker}`. No processes, no side effects — pipe the
  events wherever they should go.

      tracker = GameEvents.new()

      {events, tracker} = GameEvents.step(tracker, gamestate)
      Enum.each(events, &handle_event/1)

  ## Events

    * `{:game_start, %{stage: id, players: %{port => character_id}}}` —
      a menu-to-in-game transition
    * `{:game_end, %{stocks: %{port => stocks_left}}}` — in-game to menu
    * `{:stock_lost, %{port: p, remaining: n, kind: :sd | :ko,
      percent_before: pct}}` — a port's stock count fell. Trajectory
      classified: `:ko` when the player entered a hitstun ACTION at any
      point since they last touched ground or ledge — i.e. the fall was
      *caused*; `:sd` when the fall was untouched, at ANY percent. This
      replaces the percent<20 heuristic, which was wrong both ways
      (GOTCHA #94: high-percent walk-offs read as KOs, low-percent
      spikes read as SDs). Action states only: `hitstun_frames_left`
      (misc_as) is a union field with unrelated meanings outside damage
      actions, and consulting it misread untouched falls as KOs.
    * `{:shield_break, %{port: p}}` — a shielding action transitioned
      into the break family (205..211, ShieldBreakFly/…/FuraFura)
    * `{:menu_transition, %{from: m1, to: m2}}` — any menu-state change
      that isn't a game boundary
    * `{:l_cancel, %{port: p, success: boolean}}` — an aerial landing
      resolved its L-cancel (Slippi post-frame 0x33; one event per
      landing)
    * `{:conversion, %{by: p, against: q, start_frame: f0,
      end_frame: f1, moves: [%{frame, move_id, damage}], damage: total,
      did_kill: boolean, opening: :neutral_win | :counter_attack |
      :trade}}` — a punish in the slippi-js `ConversionComputer` mold:
      OPENS when a player takes attributed damage (`last_hit_by`),
      ACCUMULATES every further damage instance as a move (move ids
      from the attacker's `last_attack_landed`), and CLOSES once the
      defender has been out of combo states (hitstun / grabbed /
      tumble / hitlag) for #{45} consecutive frames — or dies
      (`did_kill: true`), or the game ends. The opening classifies as
      `:counter_attack` when the attacker was themselves being
      converted at the time, `:trade` when the attacker took damage
      within the previous 5 frames, `:neutral_win` otherwise.

  Conversions are the dense-reward signal: "won neutral" and "damage
  per opening" fall out of this stream without replay post-processing.
  `Melee.GameEvents.Stats` folds these events into per-game summaries.
  """

  alias Melee.GameState

  # Hitstun action families (DamageHigh1..DamageFlyRoll) — the same set
  # ExPhil's GroundTruth / edge_snippet_mine trajectory classifier uses.
  @hitstun_states MapSet.new(Enum.to_list(75..91) ++ Enum.to_list(223..232))
  # CliffCatch/CliffWait: grabbing ledge is a "safe" reset, same as ground.
  @ledge_states MapSet.new([252, 253])

  # Shield action states (GuardOn/Guard/GuardOff) and the hard-break
  # family they can transition into (ShieldBreakFly .. FuraFura) — same
  # sets as ExPhil's Interp.ReplayStats.
  @shield_states MapSet.new([178, 179, 180])
  @shield_break_states MapSet.new(205..211)

  # Aerial-landing actions (NairLanding..DairLanding): entering one is
  # the moment the L-cancel status (post-frame 0x33) is authoritative.
  @aerial_landing_states MapSet.new(70..74)

  # States that keep a conversion alive (defender not yet reset):
  # hitstun/thrown families plus tumble. The reset counter runs only
  # while the defender is OUT of these (and out of hitlag); slippi-js's
  # PUNISH_RESET_FRAMES.
  @combo_states MapSet.new(Enum.to_list(75..91) ++ Enum.to_list(223..232) ++ [38])
  @conversion_reset_frames 45
  @trade_window_frames 5

  @type event ::
          {:game_start, map()}
          | {:game_end, map()}
          | {:stock_lost, map()}
          | {:shield_break, map()}
          | {:menu_transition, map()}
          | {:l_cancel, map()}
          | {:conversion, map()}

  @type t :: %__MODULE__{
          in_game: boolean(),
          menu_state: integer() | nil,
          players: %{optional(integer()) => map()},
          conversions: %{optional(integer()) => map()},
          frame: integer() | nil
        }

  defstruct in_game: false, menu_state: nil, players: %{}, conversions: %{}, frame: nil

  @doc "Fresh tracker. Feed it `step/2` per gamestate."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Flush the tracker at end of stream: returns the `{:game_end, %{stocks:
  ...}}` the in-game -> menu transition would have produced, or `[]` if
  no game was in progress.

  Exists for replay files: a `.slp` stops AT Melee's GAME_END, so no
  menu frame ever follows and `step/2` alone can never emit the
  `:game_end`. Live consumers don't need this — menus follow a game —
  but calling it after a disconnect is also correct.

      {events, tracker} = Enum.reduce(frames, {[], GameEvents.new()}, ...)
      events ++ GameEvents.finish(tracker)
  """
  @spec finish(t()) :: [event()]
  def finish(%__MODULE__{in_game: false}), do: []

  def finish(%__MODULE__{} = tracker) do
    flush_conversions(tracker) ++
      [{:game_end, %{stocks: Map.new(tracker.players, fn {port, p} -> {port, p.stock} end)}}]
  end

  @doc """
  Lazily turn any enumerable of gamestates into a stream of events,
  with the end-of-stream `finish/1` flush built in.

  Composes with both halves of the library:

      # A replay file, events end to end (:game_end included):
      "game.slp" |> Melee.SlpFile.stream!() |> Melee.GameEvents.stream()

      # A live session, scored as it plays:
      session
      |> Melee.Session.stream()
      |> Melee.GameEvents.stream()
      |> Enum.each(&IO.inspect/1)
  """
  @spec stream(Enumerable.t()) :: Enumerable.t()
  def stream(gamestates) do
    Stream.transform(
      gamestates,
      fn -> new() end,
      fn gamestate, tracker -> step(tracker, gamestate) end,
      fn tracker -> {finish(tracker), tracker} end,
      fn _tracker -> :ok end
    )
  end

  @doc """
  Fold one gamestate: returns `{events, tracker}` with the events this
  frame produced, oldest first.
  """
  @spec step(t(), GameState.t()) :: {[event()], t()}
  def step(%__MODULE__{} = tracker, %GameState{} = gamestate) do
    in_game = GameState.in_game?(gamestate)

    events =
      cond do
        in_game and not tracker.in_game ->
          [
            {:game_start,
             %{
               stage: gamestate.stage,
               players: Map.new(known_players(gamestate), fn {port, p} -> {port, p.character} end)
             }}
          ]

        not in_game and tracker.in_game ->
          flush_conversions(tracker) ++
            [
              {:game_end,
               %{stocks: Map.new(tracker.players, fn {port, p} -> {port, p.stock} end)}}
            ]

        not in_game and tracker.menu_state != nil and
            gamestate.menu_state != tracker.menu_state ->
          [{:menu_transition, %{from: tracker.menu_state, to: gamestate.menu_state}}]

        true ->
          []
      end

    # Per-port diffs only make sense across two consecutive IN-GAME
    # frames — respawn resets and menu screens would read as deaths.
    {events, conversions} =
      if in_game and tracker.in_game do
        {conv_events, conversions} = step_conversions(tracker, gamestate)

        {events ++
           player_events(tracker.players, known_players(gamestate)) ++ conv_events, conversions}
      else
        {events, %{}}
      end

    # hit_since_safe only carries across consecutive in-game frames — a
    # fresh game must not inherit the previous game's hitstun state.
    prev_flags = if tracker.in_game, do: tracker.players, else: %{}

    tracker = %__MODULE__{
      in_game: in_game,
      menu_state: gamestate.menu_state,
      frame: if(in_game, do: gamestate.frame, else: tracker.frame),
      conversions: conversions,
      players:
        if(in_game,
          do: Map.new(known_players(gamestate), &snapshot(&1, prev_flags, gamestate.frame)),
          else: tracker.players
        )
    }

    {events, tracker}
  end

  defp known_players(%GameState{players: players}) do
    for {port, p} <- players || %{}, p != nil, do: {port, p}
  end

  defp snapshot({port, p}, prev_flags, frame) do
    action = int(p.action)

    # Action states ONLY — deliberately not `hitstun_frames_left > 0`.
    # That field decodes misc_as (0x2B), a UNION whose meaning depends
    # on the action: it is hitstun remaining only during damage
    # actions, and carries unrelated data otherwise. Reading it
    # unconditionally classified an untouched dash-off-the-edge at
    # 0.0% as a KO in a live 4-player game (caught by the 4p smoke
    # test).
    hit? = MapSet.member?(@hitstun_states, action)

    safe? = p.on_ground == true or MapSet.member?(@ledge_states, action)

    hit_since_safe =
      cond do
        hit? -> true
        safe? -> false
        true -> get_in(prev_flags, [port, :hit_since_safe]) || false
      end

    prev_percent = get_in(prev_flags, [port, :percent])

    last_damaged_frame =
      if is_number(prev_percent) and p.percent > prev_percent + 0.001,
        do: frame,
        else: get_in(prev_flags, [port, :last_damaged_frame])

    {port,
     %{
       stock: p.stock,
       percent: p.percent,
       action: p.action,
       character: p.character,
       hit_since_safe: hit_since_safe,
       last_damaged_frame: last_damaged_frame
     }}
  end

  defp player_events(prev_players, current) do
    Enum.flat_map(current, fn {port, p} ->
      case prev_players do
        %{^port => prev} -> diff_player(port, prev, p)
        _ -> []
      end
    end)
  end

  defp diff_player(port, prev, p) do
    stock_events =
      if is_integer(prev.stock) and is_integer(p.stock) and p.stock < prev.stock do
        # Classified off the PRE-death frame's trajectory flag: hit at
        # some point since last touching ground/ledge = a caused fall.
        kind = if Map.get(prev, :hit_since_safe, false), do: :ko, else: :sd

        [
          {:stock_lost,
           %{port: port, remaining: p.stock, kind: kind, percent_before: prev.percent}}
        ]
      else
        []
      end

    break_events =
      if MapSet.member?(@shield_states, int(prev.action)) and
           MapSet.member?(@shield_break_states, int(p.action)) do
        [{:shield_break, %{port: port}}]
      else
        []
      end

    stock_events ++ break_events ++ l_cancel_events(port, prev, p)
  end

  # One event per aerial landing, read at the moment the landing action
  # is entered (the frame post-frame 0x33 is authoritative).
  defp l_cancel_events(port, prev, p) do
    if not MapSet.member?(@aerial_landing_states, int(prev.action)) and
         MapSet.member?(@aerial_landing_states, int(p.action)) and p.l_cancel in [1, 2] do
      [{:l_cancel, %{port: port, success: p.l_cancel == 1}}]
    else
      []
    end
  end

  ## ------------------------------------------------------------------
  ## Conversions
  ## ------------------------------------------------------------------

  # Walk every port with a previous snapshot: open/extend a conversion
  # on attributed damage, run the reset counter otherwise, close on
  # reset expiry or death.
  defp step_conversions(tracker, gamestate) do
    frame = gamestate.frame
    players = known_players(gamestate)

    # The move id a hit carries is the ATTACKER's last_attack_landed as
    # of this frame.
    attacker_moves = Map.new(players, fn {port, p} -> {port, p.last_attack_landed} end)

    Enum.reduce(players, {[], tracker.conversions}, fn {port, p}, {events, conversions} ->
      case tracker.players do
        %{^port => prev} ->
          step_conversion(port, prev, p, frame, tracker, attacker_moves, events, conversions)

        _ ->
          {events, conversions}
      end
    end)
  end

  defp step_conversion(port, prev, p, frame, tracker, attacker_moves, events, conversions) do
    active = Map.get(conversions, port)
    died? = is_integer(prev.stock) and is_integer(p.stock) and p.stock < prev.stock
    damaged? = is_number(prev.percent) and p.percent > prev.percent + 0.001
    attacker = p.last_hit_by

    cond do
      died? and active != nil ->
        {events ++ [close_conversion(active, frame, true)], Map.delete(conversions, port)}

      damaged? and attacker in 1..4 and attacker != port ->
        damage = Float.round(p.percent - prev.percent, 2)
        move = %{frame: frame, move_id: Map.get(attacker_moves, attacker, 0), damage: damage}
        take_hit(port, attacker, move, damage, frame, active, tracker, events, conversions)

      active != nil ->
        run_reset(port, p, frame, active, events, conversions)

      true ->
        {events, conversions}
    end
  end

  defp take_hit(port, attacker, move, damage, frame, active, tracker, events, conversions) do
    opened = %{
      by: attacker,
      against: port,
      start_frame: frame,
      moves: [move],
      damage: damage,
      reset: 0,
      opening: classify_opening(attacker, port, conversions, tracker, frame)
    }

    cond do
      active == nil ->
        {events, Map.put(conversions, port, opened)}

      active.by == attacker ->
        extended = %{
          active
          | moves: [move | active.moves],
            damage: active.damage + damage,
            reset: 0
        }

        {events, Map.put(conversions, port, extended)}

      true ->
        # A different port took over the punish: close the old
        # conversion and open a fresh one attributed to them.
        {events ++ [close_conversion(active, frame, false)], Map.put(conversions, port, opened)}
    end
  end

  defp run_reset(port, p, frame, active, events, conversions) do
    cond do
      MapSet.member?(@combo_states, int(p.action)) or p.hitlag_left > 0 ->
        {events, Map.put(conversions, port, %{active | reset: 0})}

      active.reset + 1 > @conversion_reset_frames ->
        {events ++ [close_conversion(active, frame, false)], Map.delete(conversions, port)}

      true ->
        {events, Map.put(conversions, port, %{active | reset: active.reset + 1})}
    end
  end

  defp classify_opening(attacker, defender, conversions, tracker, frame) do
    attacker_being_converted? =
      case Map.get(conversions, attacker) do
        %{by: ^defender} -> true
        _ -> false
      end

    attacker_recently_hit? =
      case get_in(tracker.players, [attacker, :last_damaged_frame]) do
        f when is_integer(f) -> frame - f <= @trade_window_frames
        _ -> false
      end

    cond do
      attacker_recently_hit? -> :trade
      attacker_being_converted? -> :counter_attack
      true -> :neutral_win
    end
  end

  defp close_conversion(active, frame, did_kill) do
    {:conversion,
     %{
       by: active.by,
       against: active.against,
       start_frame: active.start_frame,
       end_frame: frame,
       moves: Enum.reverse(active.moves),
       damage: Float.round(active.damage, 2),
       did_kill: did_kill,
       opening: active.opening
     }}
  end

  defp flush_conversions(%__MODULE__{conversions: conversions, frame: frame}) do
    for {_port, active} <- conversions do
      close_conversion(active, frame || active.start_frame, false)
    end
  end

  defp int(a) when is_integer(a), do: a
  defp int(a) when is_number(a), do: trunc(a)
  defp int(_), do: -1
end
