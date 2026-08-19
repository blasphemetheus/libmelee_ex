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

  test "an untouched fall is an SD at any percent (GOTCHA #94)" do
    # High percent, walks off, never hit while airborne: the percent<20
    # heuristic called this a KO — trajectory says SD.
    events =
      feed([
        gs(@in_game, %{1 => player(stock: 4, percent: 132.0, on_ground: true)}),
        gs(@in_game, %{1 => player(stock: 4, percent: 132.0, on_ground: false)}),
        gs(@in_game, %{1 => player(stock: 4, percent: 132.0, on_ground: false)}),
        gs(@in_game, %{1 => player(stock: 3, percent: 0.0)})
      ])

    assert [
             {:game_start, _},
             {:stock_lost, %{port: 1, remaining: 3, kind: :sd, percent_before: 132.0}}
           ] = events
  end

  test "a low-percent spike is a KO (GOTCHA #94)" do
    # Airborne, enters hitstun (DamageFlyHigh = 223) at 8%, dies: the
    # percent<20 heuristic called this an SD — trajectory says KO.
    events =
      feed([
        gs(@in_game, %{1 => player(stock: 4, percent: 0.0, on_ground: false)}),
        gs(@in_game, %{1 => player(stock: 4, percent: 8.0, on_ground: false, action: 223)}),
        gs(@in_game, %{1 => player(stock: 4, percent: 8.0, on_ground: false, action: 29)}),
        gs(@in_game, %{1 => player(stock: 3, percent: 0.0)})
      ])

    assert [
             {:game_start, _},
             {:stock_lost, %{port: 1, remaining: 3, kind: :ko, percent_before: 8.0}}
           ] = events
  end

  test "touching ground or ledge after a hit resets the trajectory to SD" do
    # Hit, recovers to ledge (CliffCatch = 252), then drops off untouched
    # and dies: the hit no longer explains the fall — SD.
    events =
      feed([
        gs(@in_game, %{1 => player(stock: 4, percent: 40.0, on_ground: false, action: 223)}),
        gs(@in_game, %{1 => player(stock: 4, percent: 40.0, on_ground: false, action: 252)}),
        gs(@in_game, %{1 => player(stock: 4, percent: 40.0, on_ground: false, action: 29)}),
        gs(@in_game, %{1 => player(stock: 3, percent: 0.0)})
      ])

    assert [
             {:game_start, _},
             {:stock_lost, %{port: 1, remaining: 3, kind: :sd, percent_before: 40.0}}
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

  describe "against a real replay" do
    @fixture Path.expand("../fixtures/fox_multishine.slp", __DIR__)

    # Golden events for the whole fixture: port 2 gets genuinely KO'd
    # (hitstun actions seen airborne), then port 1 — a multishine
    # practice session — dumps all four stocks as untouched falls,
    # including one at 27% (damage taken earlier in the stock, but the
    # fall itself uncaused: the exact high-percent-SD case the old
    # percent<20 heuristic misread, and the misc_as clause misread
    # after it). Exercises both classifier kinds on real frames.
    test "the fixture replay produces the golden event sequence" do
      {events, _tracker} =
        @fixture
        |> Melee.SlpFile.stream!()
        |> Enum.reduce({[], GameEvents.new()}, fn gs, {acc, tracker} ->
          {new, tracker} = GameEvents.step(tracker, gs)
          {acc ++ new, tracker}
        end)

      assert [
               {:game_start, %{players: %{1 => 1, 2 => 24}, stage: 25}},
               {:stock_lost, %{port: 2, kind: :ko, remaining: 3, percent_before: p2}},
               {:stock_lost, %{port: 1, kind: :sd, remaining: 3, percent_before: 27.0}},
               {:stock_lost, %{port: 1, kind: :sd, remaining: 2, percent_before: sd1}},
               {:stock_lost, %{port: 1, kind: :sd, remaining: 1, percent_before: sd2}},
               {:stock_lost, %{port: 1, kind: :sd, remaining: 0, percent_before: sd3}}
             ] = for(e = {kind, _} <- events, kind in [:game_start, :stock_lost], do: e)

      assert_in_delta p2, 21.0, 0.001
      assert Enum.all?([sd1, sd2, sd3], &(&1 == 0.0))

      # The richer layer over the same replay: nine conversions (the
      # session's shine hits and the dummy's retaliations, all between
      # ports 1 and 2). Exactly one carries did_kill — and it is NOT
      # the port-2 KO above: it is port 2's 1% jab four frames before
      # fox's first SD. `did_kill` means "the defender died inside the
      # punish window" (slippi-js's semantic), deliberately independent
      # of :stock_lost's trajectory-based SD/KO classification — the
      # two views disagree on exactly this kind of death, and both are
      # right about what they measure.
      conversions = for {:conversion, c} <- events, do: c
      assert length(conversions) == 9
      assert Enum.all?(conversions, &({&1.by, &1.against} in [{1, 2}, {2, 1}]))
      assert Enum.all?(conversions, &(&1.damage > 0 and &1.moves != []))

      assert [%{by: 2, against: 1, damage: 1.0, start_frame: 990}] =
               Enum.filter(conversions, & &1.did_kill)

      assert [{:l_cancel, %{port: 2, success: true}}] =
               for(e = {:l_cancel, _} <- events, do: e)

      # And the stats fold agrees end to end.
      stats = Melee.GameEvents.Stats.summarize(events)
      assert stats[2].kills == 1
      assert stats[2].openings_per_kill != nil
      assert stats[2].l_cancels == %{successful: 1, missed: 0, rate: 1.0}
      assert stats[1].sds == 4
      assert stats[1].conversions + stats[2].conversions == 9
    end

    # A semantic edge worth pinning: :game_end fires on the in-game ->
    # menu transition, and a replay stream stops AT Melee's GAME_END —
    # no menu frame ever arrives, so `step/2` alone cannot emit it.
    # `finish/1` is the end-of-stream flush that closes the gap.
    test "a replay stream needs finish/1 for its :game_end" do
      {events, tracker} =
        @fixture
        |> Melee.SlpFile.stream!()
        |> Enum.reduce({[], GameEvents.new()}, fn gs, {acc, tracker} ->
          {new, tracker} = GameEvents.step(tracker, gs)
          {acc ++ new, tracker}
        end)

      refute Enum.any?(events, &match?({:game_end, _}, &1))

      assert [{:game_end, %{stocks: %{1 => 0, 2 => 3}}}] = GameEvents.finish(tracker)

      # Idempotent by construction on a fresh tracker, and a no-op when
      # no game was in progress.
      assert GameEvents.finish(GameEvents.new()) == []
    end

    test "stream/1 equals the hand-rolled fold, finish included" do
      gamestates = @fixture |> Melee.SlpFile.stream!() |> Enum.to_list()

      {folded, tracker} =
        Enum.reduce(gamestates, {[], GameEvents.new()}, fn gs, {acc, tracker} ->
          {new, tracker} = GameEvents.step(tracker, gs)
          {acc ++ new, tracker}
        end)

      folded = folded ++ GameEvents.finish(tracker)
      streamed = gamestates |> GameEvents.stream() |> Enum.to_list()

      assert streamed == folded
      assert match?({:game_end, _}, List.last(streamed))
    end

    test "stream/1 is lazy" do
      # Taking the first event must not require walking the whole
      # replay: an infinite source proves it can't have been consumed.
      first =
        Stream.cycle([%GameState{menu_state: 2, players: %{1 => %PlayerState{stock: 4}}}])
        |> GameEvents.stream()
        |> Enum.take(1)

      assert [{:game_start, _}] = first
    end
  end

  describe "conversions" do
    defp in_game_frame(frame, players), do: %{gs(@in_game, players) | frame: frame}

    defp standing(port_attrs), do: player(Keyword.merge([on_ground: true], port_attrs))

    test "opens on attributed damage, accumulates moves, closes on reset" do
      base = %{1 => standing([]), 2 => standing(character: 10)}

      hit1 = %{
        1 => standing(last_attack_landed: 13),
        2 => player(character: 10, percent: 12.0, action: 75, last_hit_by: 1)
      }

      hit2 = %{
        1 => standing(last_attack_landed: 17),
        2 => player(character: 10, percent: 25.0, action: 76, last_hit_by: 1)
      }

      reset_frames =
        for i <- 5..55 do
          in_game_frame(i, %{
            1 => standing([]),
            2 => standing(character: 10, percent: 25.0, last_hit_by: 1)
          })
        end

      events =
        feed(
          [
            in_game_frame(0, base),
            in_game_frame(1, base),
            in_game_frame(2, hit1),
            in_game_frame(3, hit1),
            in_game_frame(4, hit2)
          ] ++ reset_frames
        )

      assert [{:conversion, conv}] = for({:conversion, _} = e <- events, do: e)
      assert conv.by == 1
      assert conv.against == 2
      assert conv.damage == 25.0
      assert conv.did_kill == false
      assert conv.opening == :neutral_win
      assert [%{move_id: 13, damage: 12.0}, %{move_id: 17, damage: 13.0}] = conv.moves
    end

    test "a death closes the conversion with did_kill" do
      events =
        feed([
          in_game_frame(0, %{1 => standing([]), 2 => standing(character: 10)}),
          in_game_frame(1, %{
            1 => standing(last_attack_landed: 20),
            2 => player(character: 10, percent: 80.0, action: 88, last_hit_by: 1)
          }),
          in_game_frame(2, %{
            1 => standing([]),
            2 => player(character: 10, percent: 0.0, stock: 3, action: 14, last_hit_by: 1)
          })
        ])

      assert [{:conversion, conv}] = for({:conversion, _} = e <- events, do: e)
      assert conv.did_kill == true
      # The stock_lost event still fires independently.
      assert Enum.any?(events, &match?({:stock_lost, %{port: 2}}, &1))
    end

    test "hitting back mid-punish opens a :counter_attack" do
      events =
        feed([
          in_game_frame(0, %{1 => standing([]), 2 => standing(character: 10)}),
          # 1 opens on 2.
          in_game_frame(1, %{
            1 => standing(last_attack_landed: 13),
            2 => player(character: 10, percent: 10.0, action: 75, last_hit_by: 1)
          }),
          # 40 frames later (outside the trade window), 2 hits 1 back.
          in_game_frame(41, %{
            1 => player(percent: 15.0, action: 75, last_hit_by: 2),
            2 =>
              player(
                character: 10,
                percent: 10.0,
                action: 75,
                last_hit_by: 1,
                last_attack_landed: 5
              )
          })
        ])

      tracker_events = for {:conversion, _} = e <- events, do: e
      # Neither conversion closed yet; force them out via finish.
      assert tracker_events == []
    end

    test "finish flushes open conversions" do
      {events, tracker} =
        Enum.reduce(
          [
            in_game_frame(0, %{1 => standing([]), 2 => standing(character: 10)}),
            in_game_frame(1, %{
              1 => standing(last_attack_landed: 13),
              2 => player(character: 10, percent: 10.0, action: 75, last_hit_by: 1)
            })
          ],
          {[], GameEvents.new()},
          fn state, {acc, tracker} ->
            {events, tracker} = GameEvents.step(tracker, state)
            {acc ++ events, tracker}
          end
        )

      flushed = events ++ GameEvents.finish(tracker)
      assert [{:conversion, conv}] = for({:conversion, _} = e <- flushed, do: e)
      assert conv.by == 1 and conv.did_kill == false
    end
  end

  describe "l_cancel events" do
    test "one event per aerial landing, success from the status byte" do
      base = %{1 => player(action: 0x41, on_ground: false)}
      landing_ok = %{1 => player(action: 70, on_ground: true, l_cancel: 1)}
      landing_miss = %{1 => player(action: 70, on_ground: true, l_cancel: 2)}
      air = %{1 => player(action: 0x41, on_ground: false)}

      events =
        feed([
          gs(@in_game, base),
          gs(@in_game, base),
          gs(@in_game, landing_ok),
          gs(@in_game, landing_ok),
          gs(@in_game, air),
          gs(@in_game, landing_miss)
        ])

      assert [
               {:l_cancel, %{port: 1, success: true}},
               {:l_cancel, %{port: 1, success: false}}
             ] = for({:l_cancel, _} = e <- events, do: e)
    end
  end
end
