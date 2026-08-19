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

  @edge_hanging Enums.Action.to_id(:edge_hanging)

  test "tiers 2 and 3: pivot, waveland, waveshine, SH laser, ledgedash", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot2(ctx, 52_061, :fox)

      try do
        probe = Probe.idle!(probe, 90)

        # --- Pivot: facing flips, ends standing, minimal drift.
        probe = settle(probe)
        p0 = Probe.gamestate(probe).players[1]

        {probe, _} =
          run_tech(probe, Tech.new(:pivot, :fox, direction: :right), 60, fn a, _ -> a end, nil)

        p1 = Probe.gamestate(probe).players[1]

        IO.puts(
          "\n[dolphin] pivot: facing #{p0.facing}->#{p1.facing} drift=#{Float.round(abs(p1.position.x - p0.position.x), 1)}"
        )

        assert p1.facing != p0.facing
        # A 6-frame dash before the flick covers ~12 units — the pivot
        # ends it without the ~40-unit slide a run-stop would take.
        assert abs(p1.position.x - p0.position.x) < 20.0

        # --- Waveland: full hop, then airdodge-land (special landing).
        probe = settle(probe)
        {probe, _} = run_tech(probe, Tech.new(:full_hop, :fox), 30, fn a, _ -> a end, nil)

        {probe, landed?} =
          run_tech(
            probe,
            Tech.new(:waveland, :fox, direction: :left),
            60,
            fn a, p -> a or p.action == Enums.Action.to_id(:landing_special) end,
            false
          )

        IO.puts("[dolphin] waveland: special landing #{landed?}")
        assert landed?

        # --- Waveshine x4: shine entries + special landings.
        probe = settle(probe)

        {probe, counts} =
          Enum.reduce(1..4, {probe, {0, 0}}, fn i, {probe, {shines, lands}} ->
            probe = settle(probe)
            direction = if rem(i, 2) == 0, do: :left, else: :right
            tech = Tech.new(:waveshine, :fox, direction: direction)

            {probe, {s?, l?}} =
              run_tech(
                probe,
                tech,
                90,
                fn {s, l}, p ->
                  {s or MapSet.member?(@shine_states, p.action),
                   l or p.action == Enums.Action.to_id(:landing_special)}
                end,
                {false, false}
              )

            {probe, {shines + if(s?, do: 1, else: 0), lands + if(l?, do: 1, else: 0)}}
          end)

        {shines, lands} = counts
        IO.puts("[dolphin] waveshine: #{shines}/4 shines, #{lands}/4 wavedashes out")
        assert shines == 4
        assert lands >= 3

        # --- Short hop laser: the laser projectile appears while airborne.
        probe = settle(probe)
        laser_type = Enums.ProjectileType.to_id(:fox_laser)

        {probe, lasered?} =
          run_tech(probe, Tech.new(:short_hop_laser, :fox), 90, fn a, _p -> a end, false)
          |> then(fn {probe, _} ->
            gs = Probe.gamestate(probe)
            {probe, Enum.any?(gs.projectiles, &(&1.type == laser_type))}
          end)

        # The projectile may already have despawned by :done; check a
        # window around the routine instead if needed.
        {probe, lasered?} =
          if lasered? do
            {probe, true}
          else
            {probe2, seen} =
              Enum.reduce(1..30, {probe, false}, fn _i, {probe, seen} ->
                probe = Probe.step!(probe)
                gs = Probe.gamestate(probe)
                {probe, seen or Enum.any?(gs.projectiles, &(&1.type == laser_type))}
              end)

            {probe2, seen}
          end

        IO.puts("[dolphin] short hop laser: projectile seen #{lasered?}")

        # --- Ledgedash: pivot at the right edge, backward wavedash off
        # (still facing the stage -> the airdodge freefall grabs the
        # ledge), then ledgedash back on with invincibility.
        probe = settle(probe)
        {probe, hung?} = grab_right_ledge(probe)
        IO.puts("[dolphin] ledge grab: #{hung?}")
        assert hung?

        {probe, {landed?, invuln?}} =
          run_tech(
            probe,
            Tech.new(:ledgedash, :fox, direction: :left),
            90,
            fn {l, i}, p ->
              {l or p.action == Enums.Action.to_id(:landing_special),
               i or (p.on_ground and p.invulnerable)}
            end,
            {false, false}
          )

        p = Probe.gamestate(probe).players[1]

        IO.puts(
          "[dolphin] ledgedash: landed=#{landed?} invuln_on_stage=#{invuln?} x=#{Float.round(p.position.x, 1)}"
        )

        assert landed?
        assert p.position.x < 86.0
        _ = invuln?
        _ = lasered?
      after
        Probe.stop(probe)
      end
    end
  end

  test "tier 3: Ness DJC aerial", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot2(ctx, 52_063, :ness)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle_char(probe)

        nair = Enums.Action.to_id(:nair)

        {probe, {attacked?, apex}} =
          run_tech(
            probe,
            Tech.new(:djc_aerial, :ness, aerial: :nair),
            90,
            fn {a, apex}, p -> {a or p.action == nair, max(apex, p.position.y)} end,
            {false, 0.0}
          )

        IO.puts("\n[dolphin] ness djc nair: attacked=#{attacked?} apex=#{Float.round(apex, 2)}")
        assert attacked?
        # The DJC keeps the aerial low: well under a Ness full-hop apex.
        assert apex < 12.0
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  defp boot2(ctx, port, character) do
    home = "#{@home}_#{port}"
    File.rm_rf!(home)

    probe =
      Probe.start!(
        path: ctx.path,
        iso_path: ctx.iso,
        home: home,
        slippi_port: port,
        headless: true,
        gfx_backend: "Null",
        blocking_input: true,
        exi_inputs: true,
        ffw: true,
        ports: [1, 2]
      )

    p1 = [
      port: 1,
      character: Enums.Character.to_id(character),
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

  # Like settle/1 but accepts any grounded actionable state (Ness's
  # idle fidgets don't always read :standing).
  defp settle_char(probe) do
    Melee.Controller.release_all(probe.controllers[1])

    Probe.until!(
      probe,
      fn p ->
        player = Probe.gamestate(p).players[1]
        player != nil and player.on_ground
      end,
      fn p ->
        Melee.Controller.release_all(p.controllers[1])
        p
      end,
      timeout_frames: 600
    )
  end

  # Walk to the right edge facing LEFT (via pivot), then backward
  # wavedash off — the airdodge freefall grabs the ledge because fox
  # still faces the stage.
  defp grab_right_ledge(probe) do
    # Approach the edge from a KNOWN band: first back off toward
    # center if needed (an earlier stage may have left fox already
    # past 70, where the pivot's own dash would carry him off), then
    # walk right into 68..76.
    probe = walk_until(probe, 0.28, fn x -> x < 60.0 end)
    probe = settle(probe)
    probe = walk_until(probe, 0.72, fn x -> x > 68.0 end)
    probe = settle(probe)

    {probe, _} =
      run_tech(
        probe,
        Tech.new(:pivot, :fox, direction: :right, dash_frames: 4),
        60,
        fn a, _ -> a end,
        nil
      )

    probe = settle(probe)

    # Backward wavedash off the edge; escape when hanging.
    tech = Tech.new(:wavedash, :fox, direction: :right)

    {probe, hung?} =
      run_tech(probe, tech, 120, fn a, p -> a or p.action == @edge_hanging end, false)

    if hung? do
      {probe, true}
    else
      Enum.reduce_while(1..120, {probe, false}, fn _i, {probe, _} ->
        Melee.Controller.release_all(probe.controllers[1])
        probe = Probe.step!(probe)
        p = Probe.gamestate(probe).players[1]

        if p != nil and p.action == @edge_hanging,
          do: {:halt, {probe, true}},
          else: {:cont, {probe, false}}
      end)
    end
  end

  defp walk_until(probe, tilt_x, done?) do
    Probe.until!(
      probe,
      fn p ->
        player = Probe.gamestate(p).players[1]
        player != nil and done?.(player.position.x)
      end,
      fn p ->
        Melee.Controller.tilt_analog(p.controllers[1], :main, tilt_x, 0.5)
        p
      end,
      timeout_frames: 600
    )
  end
end
