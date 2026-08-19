defmodule Melee.Integration.ConversionsTest do
  use ExUnit.Case

  @moduledoc """
  The rich event layer proven live, with `Melee.Tech` as the actor:
  Fox walks to Falco and SHFFL-nairs him twice. The `Melee.GameEvents`
  stream over those frames must contain the successful `:l_cancel`
  events (cross-checking Tech's pulsed cancel against the game's own
  post-frame verdict) and a `:conversion` attributed by `last_hit_by`
  with real damage and move entries.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_conversions
  """

  alias Melee.{Controller, Enums, GameEvents, Probe, Tech}

  @moduletag :dolphin
  @moduletag :dolphin_conversions
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_conversions_it")

  setup_all do
    path = System.get_env("MELEE_DOLPHIN_PATH")
    iso = System.get_env("MELEE_ISO_PATH")

    if path == nil or iso == nil do
      {:ok, skip: "set MELEE_DOLPHIN_PATH and MELEE_ISO_PATH"}
    else
      File.rm_rf!(@home)
      {:ok, path: Path.expand(path), iso: Path.expand(iso)}
    end
  end

  test "a SHFFL punish shows up as l_cancels and an attributed conversion", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx)

      try do
        probe = Probe.idle!(probe, 90)
        tracker = GameEvents.new()

        # Walk into range, then SHFFL nair twice; fold events all along.
        {probe, tracker, events} = approach(probe, tracker, 600)
        gs0 = Probe.gamestate(probe)

        IO.puts(
          "after approach: p1=#{Float.round(gs0.players[1].position.x, 1)} " <>
            "p2=#{Float.round(gs0.players[2].position.x, 1)}"
        )

        {probe, tracker, events2} = shffl_twice(probe, tracker, 400)
        events = events ++ events2

        # Drain the reset window so the conversion closes.
        {probe, _tracker, events3} =
          idle_folding(probe, tracker, 90)

        events = events ++ events3
        gs1 = Probe.gamestate(probe)

        IO.puts(
          "after shffls: p2 percent=#{gs1.players[2].percent} p1=#{Float.round(gs1.players[1].position.x, 1)}"
        )

        l_cancels = for {:l_cancel, e} <- events, e.port == 1, do: e
        conversions = for {:conversion, c} <- events, c.by == 1, do: c

        IO.puts(
          "\n[dolphin] conversions: l_cancels=#{inspect(l_cancels)} " <>
            "conversions=#{length(conversions)} " <>
            "damage=#{inspect(Enum.map(conversions, & &1.damage))}"
        )

        assert Enum.count(l_cancels, & &1.success) >= 1
        assert conversions != []

        best = Enum.max_by(conversions, & &1.damage)
        assert best.against == 2
        assert best.damage > 8.0
        assert length(best.moves) >= 1
        assert best.opening == :neutral_win
      after
        Probe.stop(probe)
      end
    end
  end

  defp boot(ctx) do
    probe =
      Probe.start!(
        path: ctx.path,
        iso_path: ctx.iso,
        home: @home,
        slippi_port: 52_051,
        headless: true,
        gfx_backend: "Null",
        blocking_input: true,
        exi_inputs: true,
        ffw: true,
        ports: [1, 2]
      )

    p1 = [
      port: 1,
      character: Enums.Character.to_id(:fox),
      stage: Enums.Stage.to_id(:final_destination)
    ]

    p2 = [
      port: 2,
      character: Enums.Character.to_id(:falco),
      stage: Enums.Stage.to_id(:final_destination)
    ]

    Probe.drive!(
      probe,
      fn probe ->
        gs = Probe.gamestate(probe)
        Melee.GameState.in_game?(gs) and gs.frame >= 0 and gs.players[1] != nil
      end,
      fn probe -> [Keyword.put(p1, :autostart, Probe.autostart?(probe, [p2])), p2] end,
      timeout_frames: 20_000
    )
  end

  defp fold(probe, tracker) do
    {events, tracker} = GameEvents.step(tracker, Probe.gamestate(probe))
    {tracker, events}
  end

  defp idle_folding(probe, tracker, frames) do
    Enum.reduce(1..frames, {probe, tracker, []}, fn _i, {probe, tracker, events} ->
      Controller.release_all(probe.controllers[1])
      probe = Probe.step!(probe)
      {tracker, new} = fold(probe, tracker)
      {probe, tracker, events ++ new}
    end)
  end

  defp approach(probe, tracker, budget) do
    Enum.reduce_while(1..budget, {probe, tracker, []}, fn _i, {probe, tracker, events} ->
      gs = Probe.gamestate(probe)
      me = gs.players[1]
      other = gs.players[2]
      dx = other.position.x - me.position.x

      if abs(dx) < 4.0 do
        Controller.release_all(probe.controllers[1])
        {:halt, {probe, tracker, events}}
      else
        Controller.tilt_analog(probe.controllers[1], :main, if(dx > 0, do: 0.72, else: 0.28), 0.5)
        probe = Probe.step!(probe)
        {tracker, new} = fold(probe, tracker)
        {:cont, {probe, tracker, events ++ new}}
      end
    end)
  end

  defp shffl_twice(probe, tracker, budget) do
    Enum.reduce(1..2, {probe, tracker, []}, fn _n, {probe, tracker, events} ->
      # Come to a stop between reps so the tech starts from standing.
      {probe, tracker, events} =
        Enum.reduce(1..30, {probe, tracker, events}, fn _j, {probe, tracker, events} ->
          Controller.release_all(probe.controllers[1])
          probe = Probe.step!(probe)
          {tracker, new} = fold(probe, tracker)
          {probe, tracker, events ++ new}
        end)

      tech = Tech.new(:shffl, :fox, aerial: :nair)

      Enum.reduce_while(1..budget, {probe, tracker, events, tech}, fn _i,
                                                                      {probe, tracker, events,
                                                                       tech} ->
        player = Probe.gamestate(probe).players[1]
        {status, tech} = Tech.step(tech, player, probe.controllers[1])
        probe = Probe.step!(probe)
        {tracker, new} = fold(probe, tracker)

        if status == :done,
          do: {:halt, {probe, tracker, events ++ new}},
          else: {:cont, {probe, tracker, events ++ new, tech}}
      end)
      |> case do
        {probe, tracker, events} -> {probe, tracker, events}
        {probe, tracker, events, _tech} -> {probe, tracker, events}
      end
    end)
  end
end
