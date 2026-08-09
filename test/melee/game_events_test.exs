defmodule Melee.GameEventsTest do
  use ExUnit.Case, async: true

  alias Melee.{GameEvents, GameState, PlayerState}

  @in_game 2
  @css 0
  @stage_select 1

  defp gs(menu_state, players \\ %{}) do
    %GameState{menu_state: menu_state, stage: 0x19, players: players}
  end

  defp player(attrs) do
    struct!(PlayerState, Keyword.merge([character: 2, stock: 4, percent: 0.0, action: 14], attrs))
  end

  defp feed(states) do
    {events, _tracker} =
      Enum.reduce(states, {[], GameEvents.new()}, fn state, {acc, tracker} ->
        {events, tracker} = GameEvents.step(tracker, state)
        {acc ++ events, tracker}
      end)

    events
  end

  test "game start and end bracket the session" do
    players = %{1 => player([]), 2 => player(character: 10)}

    events =
      feed([
        gs(@css, players),
        gs(@in_game, players),
        gs(@in_game, players),
        gs(@css, players)
      ])

    assert [{:game_start, start}, {:game_end, finish}] = events
    assert start.stage == 0x19
    assert start.players == %{1 => 2, 2 => 10}
    assert finish.stocks == %{1 => 4, 2 => 4}
  end

  test "menu transitions are reported between menus, not at game boundaries" do
    events = feed([gs(@css), gs(@stage_select), gs(@in_game), gs(@css)])

    assert [
             {:menu_transition, %{from: @css, to: @stage_select}},
             {:game_start, _},
             {:game_end, _}
           ] = events
  end

  test "a low-percent death is an SD, a high-percent death a KO" do
    events =
      feed([
        gs(@in_game, %{1 => player(stock: 4, percent: 2.0)}),
        gs(@in_game, %{1 => player(stock: 4, percent: 2.0)}),
        gs(@in_game, %{1 => player(stock: 3, percent: 0.0)}),
        gs(@in_game, %{1 => player(stock: 3, percent: 132.0)}),
        gs(@in_game, %{1 => player(stock: 2, percent: 0.0)})
      ])

    assert [
             {:game_start, _},
             {:stock_lost, %{port: 1, remaining: 3, kind: :sd, percent_before: 2.0}},
             {:stock_lost, %{port: 1, remaining: 2, kind: :ko, percent_before: 132.0}}
           ] = events
  end

  test "shield into the break family emits shield_break" do
    events =
      feed([
        # 179 = Guard, 205 = ShieldBreakFly
        gs(@in_game, %{1 => player(action: 179)}),
        gs(@in_game, %{1 => player(action: 179)}),
        gs(@in_game, %{1 => player(action: 205)}),
        gs(@in_game, %{1 => player(action: 206)})
      ])

    assert [{:game_start, _}, {:shield_break, %{port: 1}}] = events
  end

  test "respawn percent reset across a menu never reads as a death" do
    events =
      feed([
        gs(@in_game, %{1 => player(stock: 2, percent: 80.0)}),
        gs(@css, %{1 => player(stock: 2)}),
        # New game: stocks back to 4 — no :stock_lost from the reset,
        # and the fresh game reports a start.
        gs(@in_game, %{1 => player(stock: 4, percent: 0.0)}),
        gs(@in_game, %{1 => player(stock: 4, percent: 0.0)})
      ])

    kinds = Enum.map(events, &elem(&1, 0))
    assert :stock_lost not in kinds
    assert kinds == [:game_start, :game_end, :game_start]
  end
end
