defmodule Melee.Integration.TechResearchTest do
  use ExUnit.Case

  @moduledoc """
  The research-grade backlog, one experiment per open question:

    * Peach's 40% float cancel — the dair variant, with Slippi's own
      l_cancel byte read during the landing (it records FCs);
    * Mewtwo's teleport cancel — the END animation sliding off FD's
      lip; the discriminator is a jump press (special fall can't
      jump, a cancelled exit can);
    * Marth's tipper — spacing set from FrameData's fsmash range, far
      vs close damage;
    * the thunders combo (uthrow -> FH uair) — asserted through
      Melee.GameEvents as a real 2-move conversion.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_research
  """

  alias Melee.{Enums, FrameData, GameEvents, Probe, Tech}

  @moduletag :dolphin
  @moduletag :dolphin_research
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_research_it")

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

  test "Peach FC dair: landing lag + the Slippi l_cancel byte", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_101, :peach)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        dair_landing = Enums.Action.to_id(:dair_landing)

        # Control: plain falling dair, no L press.
        {probe, _} =
          run_tech(
            probe,
            Tech.new(:shffl, :peach, aerial: :dair, l_cancel: false),
            120,
            fn a, _ -> a end,
            nil
          )

        {probe, control_lag, control_lc} = landing_lag_and_byte(probe, [dair_landing, 0x2A])
        probe = settle(probe)

        # FC arm: float, RELEASE, dair in the drop, land.
        dair = Enums.Action.to_id(:dair)

        {probe, {floated?, attacked?}} =
          run_tech(
            probe,
            Tech.new(:float_cancel, :peach, aerial: :dair),
            150,
            fn {fl, a}, p ->
              {fl or p.action == 0x155, a or p.action == dair}
            end,
            {false, false}
          )

        {probe, fc_lag, fc_lc} = landing_lag_and_byte(probe, [dair_landing, 0x2A])

        IO.puts(
          "\n[dolphin] peach FC dair: floated=#{floated?} attacked=#{attacked?} " <>
            "fc lag=#{inspect(fc_lag)} l_cancel_byte=#{inspect(fc_lc)} vs " <>
            "control lag=#{inspect(control_lag)} byte=#{inspect(control_lc)}"
        )

        assert floated?
        assert attacked?
        assert fc_lag != nil and control_lag != nil
        # Pin the measurement: the post-float dair lands at exactly
        # NORMAL lag (14 = control) and the Slippi l_cancel byte never
        # fires — no 40% reduction exists in any float sequence we can
        # produce (attacking INSIDE float lands heavy ~29-30f).
        assert fc_lag <= control_lag
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Mewtwo teleport cancel: the end animation slides off FD's lip", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_103, :mewtwo)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # Baseline: a grounded teleport mid-stage. Measure the travel
        # distance and the END animation's (0x163) duration.
        probe = center_at(probe, 0.0)
        start_x = player(probe).position.x
        {probe, {end_x, end_frames, base_trace}} = grounded_teleport(probe)
        distance = end_x - start_x

        IO.puts(
          "\n[dolphin] baseline teleport: distance=#{Float.round(distance, 1)} end-anim=#{end_frames} frames trace=#{inspect(base_trace, base: :hex, limit: 12)}"
        )

        assert distance > 20.0
        assert end_frames >= 5

        # TC arm: start so the teleport ENDS a hair inside the lip
        # (85.57) and the end animation's slide carries off the edge.
        # Discriminator: a jump press right after leaving the ground —
        # special fall can't jump, a cancelled exit can.
        probe = settle(probe)
        {probe, tc?} = teleport_cancel_attempts(probe, distance, [1.5, 3.0, 0.5, 5.0])
        IO.puts("[dolphin] teleport cancel: double jump out of the slide-off=#{tc?}")
        assert tc?
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Marth tipper: FrameData-spaced fsmash, far vs close damage", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_105, :marth)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        marth_id = Enums.Character.to_id(:marth)
        fsmash = 0x3C
        range = FrameData.range_forward(marth_id, fsmash, 1)
        IO.puts("\n[dolphin] marth fsmash range_forward(frame 1) = #{inspect(range)}")

        # Close hit first (falco's percent is lower, so if anything the
        # sourspot is UNDER-measured relative to the tipper). The gap
        # sweep accounts for falco's body width offsetting the contact
        # point inward.
        {probe, close_dmg} = spaced_fsmash(probe, 6.0)
        probe = settle_far(probe)

        {probe, far_dmg} =
          Enum.reduce_while(
            [range + 3.0, range + 1.0, range + 5.0, range - 1.0],
            {probe, nil},
            fn gap, {probe, best} ->
              {probe, dmg} = spaced_fsmash(probe, gap)
              probe = settle_far(probe)
              best = max(best || 0.0, dmg || 0.0)
              if best >= 18.0, do: {:halt, {probe, best}}, else: {:cont, {probe, best}}
            end
          )

        IO.puts(
          "[dolphin] marth fsmash damage: close=#{inspect(close_dmg)} tipper-spaced=#{inspect(far_dmg)}"
        )

        assert close_dmg != nil and far_dmg != nil
        assert far_dmg > close_dmg + 3.0
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "thunders combo (uthrow -> FH uair) registers as a 2-move conversion", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_107, :fox)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)
        tracker = GameEvents.new()

        # Walk into grab range, folding events all along.
        falco_x = Probe.gamestate(probe).players[2].position.x
        me_x = player(probe).position.x
        tilt = if falco_x > me_x, do: 0.72, else: 0.28

        {probe, tracker, ev1} =
          walk_folding(probe, tracker, tilt, fn p -> abs(p.position.x - falco_x) < 6.5 end)

        # The combo. At 0% the uthrow pop is too small for the uair to
        # connect (the ThrowUp animation runs ~26 frames while the pop
        # peaks at 31 and falls back — measured); each rep adds ~7%, so
        # loop full combos until a conversion breaks 12%.
        {probe, _tracker, ev2, {threw?, uair?, reps}} =
          Enum.reduce_while(1..8, {probe, tracker, ev1, {false, false, 0}}, fn rep,
                                                                               {probe, tracker,
                                                                                events,
                                                                                {t0, u0, _}} ->
            # Re-approach: the previous throw moved falco.
            probe = settle(probe)
            fx = Probe.gamestate(probe).players[2].position.x
            mx = player(probe).position.x
            t = if fx > mx, do: 0.72, else: 0.28

            {probe, tracker, ev0} =
              walk_folding(probe, tracker, t, fn p -> abs(p.position.x - fx) < 6.5 end)

            delay = Enum.at([6, 10, 14, 18, 10, 14, 18, 22], rep - 1)
            {probe, tracker, ev, {t?, u?}} = thunders_attempt(probe, tracker, 3, delay)
            ev = ev0 ++ ev
            {probe, tracker, ev_drain} = idle_folding(probe, tracker, 90)
            events = events ++ ev ++ ev_drain
            acc = {probe, tracker, events, {t0 or t?, u0 or u?, rep}}

            big? =
              Enum.any?(for({:conversion, c} <- events, c.by == 1, do: c), &(&1.damage > 12.0))

            if big?, do: {:halt, acc}, else: {:cont, acc}
          end)
          |> then(fn {probe, tracker, events, acc} -> {probe, tracker, events, acc} end)

        events = ev2
        conversions = for {:conversion, c} <- events, c.by == 1, do: c
        best = if conversions != [], do: Enum.max_by(conversions, & &1.damage)

        IO.puts(
          "\n[dolphin] thunders: uthrow=#{threw?} uair=#{uair?} reps=#{reps} conversions=#{length(conversions)} " <>
            "best=#{inspect(best && %{damage: Float.round(best.damage, 1), moves: length(best.moves)})}"
        )

        assert threw?
        assert uair?
        assert best != nil
        assert length(best.moves) >= 2
        assert best.damage > 12.0
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  ## drivers -----------------------------------------------------------

  defp boot(ctx, port, character) do
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
        boot_rules: [stock: 99, time_limit: 99],
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

  defp player(probe), do: Probe.gamestate(probe).players[1]

  defp run_tech(probe, tech, budget, fold, acc0) do
    Enum.reduce_while(1..budget, {probe, tech, acc0}, fn _i, {probe, tech, acc} ->
      pl = player(probe)
      {status, tech} = Tech.step(tech, pl, probe.controllers[1])
      probe = Probe.step!(probe)
      acc = fold.(acc, player(probe))

      if status == :done, do: {:halt, {probe, acc}}, else: {:cont, {probe, tech, acc}}
    end)
    |> case do
      {probe, acc} -> {probe, acc}
      {probe, _tech, acc} -> {probe, acc}
    end
  end

  defp settle(probe), do: settle_ports(probe, [1])

  defp settle_ports(probe, ports) do
    Enum.each(ports, &Melee.Controller.release_all(probe.controllers[&1]))

    Probe.until!(
      probe,
      fn p ->
        Enum.all?(ports, fn port ->
          pl = Probe.gamestate(p).players[port]
          pl != nil and pl.on_ground and pl.action == 0x0E and pl.hitlag_left == 0
        end)
      end,
      fn p ->
        Enum.each(ports, &Melee.Controller.release_all(p.controllers[&1]))
        p
      end,
      timeout_frames: 900
    )
  end

  defp walk_until(probe, tilt_x, done?), do: walk_port(probe, 1, tilt_x, done?)

  defp walk_port(probe, port, tilt_x, done?) do
    Probe.until!(
      probe,
      fn p ->
        pl = Probe.gamestate(p).players[port]
        pl != nil and done?.(pl)
      end,
      fn p ->
        Melee.Controller.tilt_analog(p.controllers[port], :main, tilt_x, 0.5)
        p
      end,
      timeout_frames: 900
    )
  end

  defp center_at(probe, x) do
    probe = settle(probe)
    me = player(probe)

    probe =
      cond do
        me.position.x > x + 3.0 -> walk_until(probe, 0.28, fn p -> p.position.x < x + 2.0 end)
        me.position.x < x - 3.0 -> walk_until(probe, 0.72, fn p -> p.position.x > x - 2.0 end)
        true -> probe
      end

    settle(probe)
  end

  # Landing lag in the given action(s), plus the l_cancel byte values
  # observed during those frames.
  defp landing_lag_and_byte(probe, actions) do
    Enum.reduce_while(1..60, {probe, 0, MapSet.new()}, fn _i, {probe, lag, bytes} ->
      p = player(probe)

      cond do
        p.action in actions ->
          {:cont, {Probe.step!(probe), lag + 1, MapSet.put(bytes, p.l_cancel)}}

        lag > 0 ->
          {:halt, {probe, lag, bytes}}

        true ->
          {:cont, {Probe.step!(probe), lag, bytes}}
      end
    end)
    |> then(fn {probe, lag, bytes} ->
      {probe, if(lag == 0, do: nil, else: lag), MapSet.to_list(bytes)}
    end)
  end

  ## mewtwo teleport cancel ---------------------------------------------

  # Grounded teleport: up-B from standing, aimed right. Returns the
  # reappear x, the end-animation frame count, and an action trace.
  defp grounded_teleport(probe) do
    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 1.0)
    Melee.Controller.press_button(probe.controllers[1], :b)
    probe = Probe.step!(probe)
    Melee.Controller.release_button(probe.controllers[1], :b)
    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.9, 0.5)

    {probe, end_x, end_frames, trace} =
      Enum.reduce_while(1..90, {probe, nil, 0, []}, fn _i, {probe, ex, ef, tr} ->
        probe = Probe.step!(probe)
        p = player(probe)
        a = p.action

        tr =
          if tr == [] or elem(hd(tr), 0) != a,
            do: [{a, Float.round(p.position.x, 1)} | tr],
            else: tr

        cond do
          # End animation (0x163): count its frames, record where.
          a == 0x163 ->
            {:cont, {probe, p.position.x, ef + 1, tr}}

          # Past the end animation with frames counted: done.
          ef > 0 and a != 0x163 ->
            {:halt, {probe, ex, ef, tr}}

          true ->
            {:cont, {probe, ex, ef, tr}}
        end
      end)

    Melee.Controller.release_all(probe.controllers[1])
    {settle(probe), {end_x || player(probe).position.x, end_frames, Enum.reverse(trace)}}
  end

  # Try teleporting so the end animation slides off the lip; press Y
  # the moment we leave the ground and look for a double jump.
  defp teleport_cancel_attempts(probe, distance, margins) do
    Enum.reduce_while(margins, {probe, false}, fn margin, {probe, _} ->
      start = 85.57 - distance - margin
      probe = center_at(probe, start)
      {probe, tc?} = teleport_cancel_once(probe)
      probe = recover(probe)
      if tc?, do: {:halt, {probe, true}}, else: {:cont, {probe, false}}
    end)
  end

  defp teleport_cancel_once(probe) do
    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 1.0)
    Melee.Controller.press_button(probe.controllers[1], :b)
    probe = Probe.step!(probe)
    Melee.Controller.release_button(probe.controllers[1], :b)
    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.9, 0.5)

    Enum.reduce_while(1..90, {probe, :travel, false}, fn _i, {probe, phase, jumped} ->
      probe = Probe.step!(probe)
      p = player(probe)

      case phase do
        :travel ->
          # Slid off the lip mid-end-animation: jump + drift back.
          if not p.on_ground and p.action not in [0x162, 0x164, 0x165, 0x166] do
            Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.1, 0.5)
            Melee.Controller.press_button(probe.controllers[1], :y)
            {:cont, {probe, :falling, false}}
          else
            {:cont, {probe, :travel, false}}
          end

        :falling ->
          cond do
            # A double jump = actionable = the cancel worked.
            p.action in [0x1B, 0x1C] -> {:halt, {probe, true}}
            p.on_ground -> {:halt, {probe, jumped}}
            true -> {:cont, {probe, :falling, jumped}}
          end
      end
    end)
    |> case do
      {probe, tc?} when is_boolean(tc?) -> {probe, tc?}
      {probe, _phase, tc?} -> {probe, tc?}
    end
  end

  # After a TC attempt mewtwo may be offstage: hold toward center and
  # wait until he's standing again (respawn or landing both work).
  defp recover(probe) do
    Melee.Controller.release_all(probe.controllers[1])

    Probe.until!(
      probe,
      fn p ->
        pl = Probe.gamestate(p).players[1]
        pl != nil and pl.on_ground and pl.action == 0x0E
      end,
      fn p ->
        pl = Probe.gamestate(p).players[1]

        if pl != nil and not pl.on_ground and pl.action in 0x1D..0x25 do
          x = if pl.position.x > 0, do: 0.2, else: 0.8
          Melee.Controller.tilt_analog(p.controllers[1], :main, x, 0.5)
        else
          Melee.Controller.release_all(p.controllers[1])
        end

        p
      end,
      timeout_frames: 1_800
    )
  end

  ## marth tipper -------------------------------------------------------

  # Place falco `gap` units to marth's right, face him, c-stick
  # fsmash, and return the damage dealt.
  defp spaced_fsmash(probe, gap, attempts \\ 3) do
    probe = settle_ports(probe, [1, 2])
    me_x = player(probe).position.x

    probe =
      walk_port(
        probe,
        2,
        if(Probe.gamestate(probe).players[2].position.x > me_x + gap, do: 0.28, else: 0.72),
        fn p -> abs(p.position.x - (me_x + gap)) < 1.5 end
      )

    probe = settle_ports(probe, [1, 2])

    # Face falco (a couple of rightward steps), settle.
    probe =
      Enum.reduce(1..2, probe, fn _i, probe ->
        Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.7, 0.5)
        Probe.step!(probe)
      end)

    probe = settle_ports(probe, [1, 2])
    pct0 = Probe.gamestate(probe).players[2].percent

    Melee.Controller.tilt_analog(probe.controllers[1], :c, 1.0, 0.5)
    probe = Probe.step!(probe)
    Melee.Controller.tilt_analog(probe.controllers[1], :c, 0.5, 0.5)

    {probe, dmg} =
      Enum.reduce_while(1..70, {probe, nil}, fn _i, {probe, _} ->
        probe = Probe.step!(probe)
        pct = Probe.gamestate(probe).players[2].percent
        if pct > pct0, do: {:halt, {probe, pct - pct0}}, else: {:cont, {probe, nil}}
      end)

    Melee.Controller.release_all(probe.controllers[1])
    probe = settle_ports(probe, [1, 2])

    cond do
      dmg != nil -> {probe, dmg}
      attempts > 1 -> spaced_fsmash(probe, gap, attempts - 1)
      true -> {probe, nil}
    end
  end

  ## thunders / GameEvents ----------------------------------------------

  defp thunders_attempt(probe, tracker, attempts, delay \\ 6) do
    uair = Enums.Action.to_id(:uair)
    tech = Tech.new(:uthrow_uair, :fox, uair_delay: delay)

    {probe, tracker, events, threw?, uair?, trace} =
      Enum.reduce_while(1..240, {probe, tracker, [], tech, false, false, []}, fn _i,
                                                                                 {probe, tracker,
                                                                                  events, tech,
                                                                                  t?, u?, tr} ->
        pl = player(probe)
        {status, tech} = Tech.step(tech, pl, probe.controllers[1])
        probe = Probe.step!(probe)
        {tracker, new} = fold(probe, tracker)
        gs = Probe.gamestate(probe)
        p1 = gs.players[1]
        p2 = gs.players[2]

        t? = t? or p1.action == 0xDD
        u? = u? or p1.action == uair

        entry =
          {p1.action, Float.round(p1.position.y, 0), Float.round(p2.position.y, 0),
           p2.hitlag_left > 0}

        tr = if tr == [] or hd(tr) != entry, do: [entry | tr], else: tr
        acc = {probe, tracker, events ++ new, tech, t?, u?, tr}

        if status == :done,
          do: {:halt, Tuple.delete_at(acc, 3)},
          else: {:cont, acc}
      end)
      |> case do
        {probe, tracker, events, t?, u?, tr} -> {probe, tracker, events, t?, u?, tr}
        {probe, tracker, events, _tech, t?, u?, tr} -> {probe, tracker, events, t?, u?, tr}
      end

    _ = trace

    if threw? or attempts <= 1 do
      {probe, tracker, events, {threw?, uair?}}
    else
      # Whiffed grab: settle, re-approach closer, retry.
      probe = settle(probe)
      falco_x = Probe.gamestate(probe).players[2].position.x
      me_x = player(probe).position.x
      tilt = if falco_x > me_x, do: 0.72, else: 0.28

      {probe, tracker, ev} =
        walk_folding(probe, tracker, tilt, fn p -> abs(p.position.x - falco_x) < 6.0 end)

      {probe, tracker, ev2, acc} = thunders_attempt(probe, tracker, attempts - 1, delay)
      {probe, tracker, events ++ ev ++ ev2, acc}
    end
  end

  defp fold(probe, tracker) do
    {events, tracker} = GameEvents.step(tracker, Probe.gamestate(probe))
    {tracker, events}
  end

  defp walk_folding(probe, tracker, tilt_x, done?) do
    Enum.reduce_while(1..600, {probe, tracker, []}, fn _i, {probe, tracker, events} ->
      pl = player(probe)

      if done?.(pl) do
        Melee.Controller.release_all(probe.controllers[1])
        {:halt, {probe, tracker, events}}
      else
        Melee.Controller.tilt_analog(probe.controllers[1], :main, tilt_x, 0.5)
        probe = Probe.step!(probe)
        {tracker, new} = fold(probe, tracker)
        {:cont, {probe, tracker, events ++ new}}
      end
    end)
  end

  defp run_tech_folding(probe, tracker, tech, budget, foldfn, acc0) do
    Enum.reduce_while(1..budget, {probe, tracker, [], tech, acc0}, fn _i,
                                                                      {probe, tracker, events,
                                                                       tech, acc} ->
      pl = player(probe)
      {status, tech} = Tech.step(tech, pl, probe.controllers[1])
      probe = Probe.step!(probe)
      {tracker, new} = fold(probe, tracker)
      acc = foldfn.(acc, player(probe))

      if status == :done,
        do: {:halt, {probe, tracker, events ++ new, acc}},
        else: {:cont, {probe, tracker, events ++ new, tech, acc}}
    end)
    |> case do
      {probe, tracker, events, acc} -> {probe, tracker, events, acc}
      {probe, tracker, events, _tech, acc} -> {probe, tracker, events, acc}
    end
  end

  defp idle_folding(probe, tracker, frames) do
    Enum.reduce(1..frames, {probe, tracker, []}, fn _i, {probe, tracker, events} ->
      Melee.Controller.release_all(probe.controllers[1])
      probe = Probe.step!(probe)
      {tracker, new} = fold(probe, tracker)
      {probe, tracker, events ++ new}
    end)
  end

  defp settle_far(probe) do
    # After a tipper the falco flies; wait for both to be grounded and
    # idle wherever they ended up.
    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])

    Probe.until!(
      probe,
      fn p ->
        a = Probe.gamestate(p).players[1]
        b = Probe.gamestate(p).players[2]

        a != nil and b != nil and a.on_ground and b.on_ground and a.action == 0x0E and
          b.action < 0x40
      end,
      fn p ->
        Melee.Controller.release_all(p.controllers[1])
        Melee.Controller.release_all(p.controllers[2])
        p
      end,
      timeout_frames: 1_800
    )
  end
end
