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
      classified: `:ko` when the player had been in hitstun (or had
      hitstun frames pending) at any point since they last touched
      ground or ledge — i.e. the fall was *caused*; `:sd` when the fall
      was untouched, at ANY percent. This replaces the percent<20
      heuristic, which was wrong both ways (GOTCHA #94: high-percent
      walk-offs read as KOs, low-percent spikes read as SDs).
    * `{:shield_break, %{port: p}}` — a shielding action transitioned
      into the break family (205..211, ShieldBreakFly/…/FuraFura)
    * `{:menu_transition, %{from: m1, to: m2}}` — any menu-state change
      that isn't a game boundary
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

  @type event ::
          {:game_start, map()}
          | {:game_end, map()}
          | {:stock_lost, map()}
          | {:shield_break, map()}
          | {:menu_transition, map()}

  @type t :: %__MODULE__{
          in_game: boolean(),
          menu_state: integer() | nil,
          players: %{optional(integer()) => map()}
        }

  defstruct in_game: false, menu_state: nil, players: %{}

  @doc "Fresh tracker. Feed it `step/2` per gamestate."
  @spec new() :: t()
  def new, do: %__MODULE__{}

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
          [
            {:game_end, %{stocks: Map.new(tracker.players, fn {port, p} -> {port, p.stock} end)}}
          ]

        not in_game and tracker.menu_state != nil and
            gamestate.menu_state != tracker.menu_state ->
          [{:menu_transition, %{from: tracker.menu_state, to: gamestate.menu_state}}]

        true ->
          []
      end

    # Per-port diffs only make sense across two consecutive IN-GAME
    # frames — respawn resets and menu screens would read as deaths.
    events =
      if in_game and tracker.in_game do
        events ++ player_events(tracker.players, known_players(gamestate))
      else
        events
      end

    # hit_since_safe only carries across consecutive in-game frames — a
    # fresh game must not inherit the previous game's hitstun state.
    prev_flags = if tracker.in_game, do: tracker.players, else: %{}

    tracker = %__MODULE__{
      in_game: in_game,
      menu_state: gamestate.menu_state,
      players:
        if(in_game,
          do: Map.new(known_players(gamestate), &snapshot(&1, prev_flags)),
          else: tracker.players
        )
    }

    {events, tracker}
  end

  defp known_players(%GameState{players: players}) do
    for {port, p} <- players || %{}, p != nil, do: {port, p}
  end

  defp snapshot({port, p}, prev_flags) do
    action = int(p.action)

    hit? =
      MapSet.member?(@hitstun_states, action) or
        (is_number(p.hitstun_frames_left) and p.hitstun_frames_left > 0)

    safe? = p.on_ground == true or MapSet.member?(@ledge_states, action)

    hit_since_safe =
      cond do
        hit? -> true
        safe? -> false
        true -> get_in(prev_flags, [port, :hit_since_safe]) || false
      end

    {port,
     %{
       stock: p.stock,
       percent: p.percent,
       action: p.action,
       character: p.character,
       hit_since_safe: hit_since_safe
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

    stock_events ++ break_events
  end

  defp int(a) when is_integer(a), do: a
  defp int(a) when is_number(a), do: trunc(a)
  defp int(_), do: -1
end
