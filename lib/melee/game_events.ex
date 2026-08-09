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
      percent_before: pct}}` — a port's stock count fell. `:sd` when the
      pre-death percent was under #{20.0} (walked/fell off with no real
      damage taken — the classifier the 2026-08-09 behavior eval used to
      separate the argmax edge-dive absorber from genuine KOs); `:ko`
      otherwise.
    * `{:shield_break, %{port: p}}` — a shielding action transitioned
      into the break family (205..211, ShieldBreakFly/…/FuraFura)
    * `{:menu_transition, %{from: m1, to: m2}}` — any menu-state change
      that isn't a game boundary
  """

  alias Melee.GameState

  # Pre-death percent below this = self-destruct, not a KO.
  @sd_percent_threshold 20.0

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
               players:
                 Map.new(known_players(gamestate), fn {port, p} -> {port, p.character} end)
             }}
          ]

        not in_game and tracker.in_game ->
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
    events =
      if in_game and tracker.in_game do
        events ++ player_events(tracker.players, known_players(gamestate))
      else
        events
      end

    tracker = %__MODULE__{
      in_game: in_game,
      menu_state: gamestate.menu_state,
      players: if(in_game, do: Map.new(known_players(gamestate), &snapshot/1), else: tracker.players)
    }

    {events, tracker}
  end

  defp known_players(%GameState{players: players}) do
    for {port, p} <- players || %{}, p != nil, do: {port, p}
  end

  defp snapshot({port, p}) do
    {port, %{stock: p.stock, percent: p.percent, action: p.action, character: p.character}}
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
        kind =
          if is_number(prev.percent) and prev.percent < @sd_percent_threshold,
            do: :sd,
            else: :ko

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
