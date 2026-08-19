defmodule Melee.Integration.TechMovementTest do
  use ExUnit.Case

  @moduledoc """
  `Melee.Tech` primitives proven in a live match, each by an assertion
  that cannot pass vacuously:

    * short hop vs full hop — the apex heights must differ the right way;
    * wavedash — repeated special-landings with real horizontal travel;
    * dash dance — direction flips while staying inside a band;
    * SHFFL — the L-cancelled nair's landing lag is measured against an
      identical no-L control run: the cancel must halve it;
    * multishine via Tech — the shine cadence matches the historical
      hand-written loop.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_movement
  """

  alias Melee.{Enums, Probe, Tech}

  @moduletag :dolphin
  @moduletag :dolphin_movement
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_movement_it")

  @knee_bend Enums.Action.to_id(:knee_bend)
  @landing_special Enums.Action.to_id(:landing_special)
  @nair_landing Enums.Action.to_id(:nair_landing)
  @shine_states MapSet.new([
                  Enums.Action.to_id(:down_b_ground_start),
                  Enums.Action.to_id(:down_b_air)
                ])

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

  test "the movement tier holds up frame-by-frame in a live match", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx)

      try do
        probe = Probe.idle!(probe, 90)

        # --- Hops: short hop apex must be well below full hop apex.
        {probe, sh_apex} = run_tech(probe, Tech.new(:short_hop, :fox), 60, &apex/2)
        probe = settle(probe)
        {probe, fh_apex} = run_tech(probe, Tech.new(:full_hop, :fox), 90, &apex/2)
        probe = settle(probe)

        IO.puts(
          "\n[dolphin] hops: short apex=#{Float.round(sh_apex, 2)} full=#{Float.round(fh_apex, 2)}"
        )

        assert sh_apex > 1.0
        assert fh_apex > sh_apex * 1.5

        # --- Wavedash: 8 in alternating directions; count special
        # landings and require real horizontal travel each time.
        {probe, {landings, travels}} = wavedashes(probe, 8)
        IO.puts("[dolphin] wavedash: #{landings}/8 special landings, travels=#{inspect(travels)}")
        assert landings >= 6
        assert Enum.count(travels, &(&1 > 5.0)) >= 6

        # --- Dash dance: flips without drifting away.
        {probe, {flips, drift}} = dash_dance(probe, 120)
        IO.puts("[dolphin] dash dance: #{flips} flips, drift=#{Float.round(drift, 1)}")
        assert flips >= 6
        assert drift < 30.0

        # --- SHFFL: cancelled vs control landing lag.
        probe = settle(probe)
        {probe, lag_cancelled} = shffl_lag(probe, l_cancel: true)
        probe = settle(probe)
        {probe, lag_control} = shffl_lag(probe, l_cancel: false)

        IO.puts(
          "[dolphin] shffl nair landing lag: l-cancel=#{lag_cancelled} control=#{lag_control}"
        )

        assert lag_cancelled != nil and lag_control != nil
        assert lag_cancelled * 2 <= lag_control + 1
        assert lag_cancelled <= 9

        # --- Multishine through Tech matches the historical cadence.
        probe = settle(probe)
        {probe, shines} = multishine(probe, 300)
        IO.puts("[dolphin] Tech multishine: #{shines} shines in 300 frames")
        assert shines >= 30

        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  ## drivers -----------------------------------------------------------

  defp boot(ctx) do
    probe =
      Probe.start!(
        path: ctx.path,
        iso_path: ctx.iso,
        home: @home,
        slippi_port: 52_041,
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

  # Run a tech until :done or budget, folding an accumulator over each
  # frame's player state.
  defp run_tech(probe, tech, budget, fold, acc0 \\ 0.0) do
    Enum.reduce_while(1..budget, {probe, tech, acc0}, fn _i, {probe, tech, acc} ->
      player = Probe.gamestate(probe).players[1]
      {status, tech} = Tech.step(tech, player, probe.controllers[1])
      probe = Probe.step!(probe)
      acc = fold.(acc, Probe.gamestate(probe).players[1])

      if status == :done, do: {:halt, {probe, acc}}, else: {:cont, {probe, tech, acc}}
    end)
    |> case do
      {probe, acc} -> {probe, acc}
      {probe, _tech, acc} -> {probe, acc}
    end
  end

  defp apex(best, player), do: max(best, player.position.y)

  # Neutral everything and wait for standing on the ground.
  defp settle(probe) do
    Melee.Controller.release_all(probe.controllers[1])

    Probe.until!(
      probe,
      fn p ->
        player = Probe.gamestate(p).players[1]
        player != nil and player.on_ground and player.action == Enums.Action.to_id(:standing)
      end,
      fn p ->
        Melee.Controller.release_all(p.controllers[1])
        p
      end,
      timeout_frames: 600
    )
  end

  defp wavedashes(probe, count) do
    Enum.reduce(1..count, {probe, {0, []}}, fn i, {probe, {landings, travels}} ->
      probe = settle(probe)
      direction = if rem(i, 2) == 0, do: :left, else: :right
      start_x = Probe.gamestate(probe).players[1].position.x
      tech = Tech.new(:wavedash, :fox, direction: direction)

      {probe, landed?} =
        run_tech(probe, tech, 60, fn acc, p -> acc or p.action == @landing_special end, false)

      # Let the slide play out before measuring travel.
      probe = Probe.idle!(probe, 15)
      travel = abs(Probe.gamestate(probe).players[1].position.x - start_x)
      {probe, {landings + if(landed?, do: 1, else: 0), travels ++ [Float.round(travel, 1)]}}
    end)
  end

  defp dash_dance(probe, frames) do
    probe = settle(probe)
    start_x = Probe.gamestate(probe).players[1].position.x
    tech = Tech.new(:dash_dance, :fox, interval: 8)

    {probe, {_tech, flips, _prev, max_drift}} =
      Enum.reduce(1..frames, {probe, {tech, 0, nil, 0.0}}, fn _i,
                                                              {probe, {tech, flips, prev, drift}} ->
        player = Probe.gamestate(probe).players[1]
        {_status, tech} = Tech.step(tech, player, probe.controllers[1])
        probe = Probe.step!(probe)
        p = Probe.gamestate(probe).players[1]

        flips = if prev != nil and p.facing != prev, do: flips + 1, else: flips
        drift = max(drift, abs(p.position.x - start_x))
        {probe, {tech, flips, p.facing, drift}}
      end)

    Melee.Controller.release_all(probe.controllers[1])
    {probe, {flips, max_drift}}
  end

  # Frames spent in NAIR_LANDING — the L-cancel halves this.
  defp shffl_lag(probe, opts) do
    tech = Tech.new(:shffl, :fox, [aerial: :nair] ++ opts)

    {probe, _} = run_tech(probe, tech, 90, fn acc, _p -> acc end, nil)

    # The tech is :done at the first landing frame; count how long the
    # landing action lasts.
    {probe, lag} =
      Enum.reduce_while(1..40, {probe, 0}, fn _i, {probe, lag} ->
        p = Probe.gamestate(probe).players[1]

        cond do
          p.action == @nair_landing -> {:cont, {Probe.step!(probe), lag + 1}}
          lag > 0 -> {:halt, {probe, lag}}
          true -> {:cont, {Probe.step!(probe), lag}}
        end
      end)

    {probe, if(lag == 0, do: nil, else: lag)}
  end

  defp multishine(probe, frames) do
    tech = Tech.new(:multishine, :fox)

    {probe, {_tech, actions}} =
      Enum.reduce(1..frames, {probe, {tech, []}}, fn _i, {probe, {tech, actions}} ->
        player = Probe.gamestate(probe).players[1]
        {_status, tech} = Tech.step(tech, player, probe.controllers[1])
        probe = Probe.step!(probe)
        {probe, {tech, [Probe.gamestate(probe).players[1].action | actions]}}
      end)

    Melee.Controller.release_all(probe.controllers[1])

    shines =
      actions
      |> Enum.reverse()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] ->
        not MapSet.member?(@shine_states, a) and MapSet.member?(@shine_states, b)
      end)

    {probe, shines}
  end
end
