defmodule Melee.Integration.TechResearchTest do
  use ExUnit.Case

  @moduledoc """
  The research-grade backlog, one experiment per open question:
  Peach float cancel (PROVEN: actionable in ~2 frames - lag must be
  measured as ACTIONABILITY, not idle animation length), Mewtwo
  teleport edge-cancel, Marth FrameData-spaced tipper, the thunders
  combo through GameEvents, Samus super wavedash (126 units), the
  Ness yo-yo glitch (the stale hitbox re-activating at 28.8 units
  mid-charge-hold), and the Ness PKT2 self-hit (a climb-then-loop
  steer plan lands the bolt on his own head; the thunder-jacket
  arming follows the cracked recipe — charge hit, clean release,
  PKT2 — but the jacket still did NOT manifest; see melee-tech.md
  for the per-component status and remaining hypotheses).

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

        # Lag is measured as ACTIONABILITY (frames from touchdown to a
        # dash coming out) — the landing ANIMATION plays ~30 frames if
        # idle but generic Landing is interruptible after its lag, an
        # artifact that produced the earlier false-negative "heavy
        # landing" readings.

        # Control: plain falling dair, no L press.
        {probe, _} =
          run_tech(
            probe,
            Tech.new(:shffl, :peach, aerial: :dair, l_cancel: false),
            120,
            fn a, _ -> a end,
            nil
          )

        {probe, control_lag} = frames_to_dash(probe)
        probe = settle(probe)

        # FC arm: dair IN the float, release + fast fall, land during
        # the attack.
        {probe, {floated?, attacked?}} =
          run_tech(
            probe,
            Tech.new(:float_cancel, :peach, aerial: :dair),
            150,
            fn {fl, a}, p ->
              {fl or p.action == 0x155, a or p.action in 0x158..0x15C}
            end,
            {false, false}
          )

        {probe, fc_lag} = frames_to_dash(probe)

        IO.puts(
          "\n[dolphin] peach FC dair: floated=#{floated?} attacked=#{attacked?} " <>
            "actionable_in=#{inspect(fc_lag)} vs control=#{inspect(control_lag)} frames"
        )

        assert floated?
        assert attacked?
        assert fc_lag != nil and control_lag != nil
        # The float cancel: a ~4-frame landing vs the dair's full lag.
        assert fc_lag <= 7
        assert control_lag >= fc_lag * 2
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
        Enum.each(ports, &nudge_settled(p, &1))
        p
      end,
      timeout_frames: 900
    )
  end

  # States that idle FOREVER on a released stick get a nudge: knocked
  # down -> getup (up-tilt), ledge hang -> climb (Y), lip teeter ->
  # step back in.
  defp nudge_settled(probe, port) do
    pl = Probe.gamestate(probe).players[port]

    cond do
      pl == nil ->
        :ok

      pl.action in 0xB7..0xC6 and pl.on_ground ->
        Melee.Controller.tilt_analog(probe.controllers[port], :main, 0.5, 1.0)

      pl.action == 0xFD ->
        Melee.Controller.press_button(probe.controllers[port], :y)

      pl.action in [0xF5, 0xF6] ->
        x = if pl.facing, do: 0.28, else: 0.72
        Melee.Controller.tilt_analog(probe.controllers[port], :main, x, 0.5)

      true ->
        Melee.Controller.release_all(probe.controllers[port])
    end
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

  # Frames from NOW (a touchdown) until a held dash input produces a
  # dash/turn — the real landing LAG, as opposed to the (longer,
  # interruptible) landing animation.
  defp frames_to_dash(probe) do
    Enum.reduce_while(1..40, {probe, 0, []}, fn _i, {probe, n, tr} ->
      Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.0, 0.5)
      probe = Probe.step!(probe)
      p = player(probe)

      tr =
        if tr == [] or elem(hd(tr), 0) != p.action,
          do: [{p.action, trunc(p.action_frame)} | tr],
          else: tr

      # A stick HELD through the landing exits into a WALK (no fresh
      # edge for a dash) - any grounded movement marks actionability.
      if p.action in [0x0F, 0x10, 0x11, 0x12, 0x14],
        do: {:halt, {probe, n, tr}},
        else: {:cont, {probe, n + 1, tr}}
    end)
    |> then(fn {probe, n, tr} ->
      Melee.Controller.release_all(probe.controllers[1])
      if n >= 40, do: IO.puts("[dash probe stuck] #{inspect(Enum.reverse(tr), base: :hex)}")
      {probe, if(n >= 40, do: nil, else: n)}
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

  test "Samus super wavedash: flick-frame sweep until the slide", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_109, :samus)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # The window is 1 frame wide; the game is deterministic, so
        # sweep the flick frame until the slide appears.
        {probe, {best_slide, best_frame}} =
          Enum.reduce_while(36..46, {probe, {0.0, nil}}, fn flick, {probe, best} ->
            # Start on the far side - the slide covers 60-80 units and
            # sails off the lip otherwise (measured the hard way).
            probe = recover(probe)
            f0 = player(probe).facing
            dir = if f0, do: :right, else: :left
            probe = center_at(probe, if(dir == :right, do: -45.0, else: 45.0))
            x0 = player(probe).position.x

            {probe, trace} =
              run_tech(
                probe,
                Tech.new(:super_wavedash, :samus, direction: dir, flick_frame: flick),
                120,
                fn tr, p ->
                  e = {p.action, trunc(p.action_frame), Float.round(p.position.x, 1)}
                  if tr == [] or elem(hd(tr), 0) != p.action, do: [e | tr], else: tr
                end,
                []
              )

            _ = trace
            slide = abs(player(probe).position.x - x0)
            probe = recover(probe)
            best = if slide > elem(best, 0), do: {slide, flick}, else: best

            if slide > 40.0,
              do: {:halt, {probe, best}},
              else: {:cont, {probe, best}}
          end)

        IO.puts(
          "\n[dolphin] super wavedash: best slide=#{Float.round(best_slide, 1)} units at flick_frame=#{inspect(best_frame)}"
        )

        assert best_slide > 40.0
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Ness yo-yo glitch: the stale hitbox re-activates at range", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_111, :ness)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # Mapped by a frame-by-frame walkthrough: the charging up
        # smash hits at ~8.6 around charge frames 11-12; at low
        # percent the target stays near and only eats the normal
        # 6-frame re-hits, but once knocked BEYOND the swing range
        # (~13), a further hit while the charge is still held is the
        # STALE hitbox re-activating (seen at 28.8 in the map run).
        # Loop the scenario - percent accumulates and the knockback
        # grows until falco parks out of normal reach.
        {probe, ranged, all_hits} =
          Enum.reduce_while(1..4, {probe, nil, []}, fn _round, {probe, _, acc} ->
            {probe, hits} = yoyo_round(probe)
            acc = acc ++ hits

            ranged =
              Enum.find(hits, fn {_, d, a, _} -> d > 15.0 and a in [0x156, 0x157] end)

            if ranged != nil,
              do: {:halt, {probe, ranged, acc}},
              else: {:cont, {probe, nil, acc}}
          end)

        IO.puts(
          "\n[dolphin] yo-yo glitch: ranged=#{inspect(ranged, base: :hex)} all hits (pct, dist, ness_action, frame)=#{inspect(all_hits, base: :hex, limit: 20)}"
        )

        assert ranged != nil
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Ness PKT2 self-hit: the steered bolt loop connects (jacket arming: exploratory)", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_113, :ness)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # TEMP map: the climb-loop plan with a visible bolt (falco
        # untouched — walking him kills the item stream's view).
        probe = center_at(probe, 0.0)

        tech0 =
          Tech.new(:pkt2, :ness,
            steer: [
              {0.5, 1.0, 11},
              {1.0, 0.5, 17},
              {0.5, 0.0, 17},
              {0.0, 0.5, 17},
              {0.0, 0.5, 45}
            ]
          )

        {probe, _tech0} =
          Enum.reduce(1..120, {probe, tech0}, fn i, {probe, tech0} ->
            ness = player(probe)
            {_s, tech0} = Tech.step(tech0, ness, probe.controllers[1])
            probe = Probe.step!(probe)
            ness = player(probe)
            bolt = List.first(Probe.gamestate(probe).projectiles)

            if i in 18..110 do
              IO.puts(
                "[pktmap] #{i}: a=#{Integer.to_string(ness.action, 16)} hitlag=#{ness.hitlag_left} " <>
                  "pct=#{ness.percent} bolt=#{inspect(bolt && {bolt.type, Float.round(bolt.position.x, 1), Float.round(bolt.position.y, 1), Float.round(bolt.speed.x, 2), Float.round(bolt.speed.y, 2), bolt.expiration_frames})}"
              )
            end

            {probe, tech0}
          end)

        Melee.Controller.release_all(probe.controllers[1])
        probe = settle_ports(probe, [1, 2])

        # Control: PKT2 into himself with NO broken charge, then falco
        # walks into ness — contact alone must deal nothing.
        {probe, control} = jacket_round(probe, nil)
        IO.puts("\n[dolphin] control (no armed yo-yo): #{inspect(control)}")

        # Armed arms: falco interrupts ness's yo-yo charge at frame k
        # (a GRAB is the canonical hitbox-storing interruption), then
        # PKT2, then the walk-in probe.
        arms = [8, 30, 45]

        {probe, result} =
          Enum.reduce_while(arms, {probe, nil}, fn arm, {probe, _} ->
            {probe, res} = jacket_round(probe, arm)
            IO.puts("[dolphin] #{inspect(arm)}: #{inspect(res)}")

            if res.jacket?,
              do: {:halt, {probe, {arm, res}}},
              else: {:cont, {probe, nil}}
          end)

        IO.puts("[dolphin] thunder jacket: #{inspect(result)}")
        assert control.pkt2?
        refute control.jacket?

        if result == nil,
          do:
            IO.puts(
              "[dolphin] grounded-recipe jacket absent as expected — the LEDGE-GRAB " <>
                "interrupt is the real method (see the thunder jacket test below)"
            )

        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  ## thunder jacket ------------------------------------------------------

  # One jacket attempt: optionally break ness's yo-yo charge with a
  # falco jab at charge frame `k`, PKT2 into himself, then the probe —
  # falco walks INTO the idle ness and only a jacket deals damage.
  # The yo-yo glitch arming, per the cracked recipe (SmashWiki /
  # smashboards): ness charges the up smash with falco in range, falco
  # takes ONLY the charge's hitbox and retreats, and ness releases the
  # charge `hold` frames after the hit with the release swing hitting
  # NOTHING — the up smash's last hitbox is left stranded. Approach is
  # the proven yoyo_round configuration (ness walks to within 16,
  # facing falco; the charge's hits register from there).
  defp arm_yoyo(probe, hold) do
    falco_x = Probe.gamestate(probe).players[2].position.x
    me_x = player(probe).position.x
    tilt = if falco_x > me_x, do: 0.72, else: 0.28
    probe = walk_until(probe, tilt, fn p -> abs(p.position.x - falco_x) < 16.0 end)
    probe = settle_ports(probe, [1, 2])

    walk_in = if falco_x > player(probe).position.x, do: 0.28, else: 0.72
    walk_out = 1.0 - walk_in

    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 1.0)
    Melee.Controller.press_button(probe.controllers[1], :a)

    {probe, hit_at} =
      Enum.reduce_while(1..120, {probe, nil}, fn i, {probe, _} ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, walk_in, 0.5)
        probe = Probe.step!(probe)
        falco = Probe.gamestate(probe).players[2]

        if falco.hitlag_left > 0,
          do: {:halt, {probe, i}},
          else: {:cont, {probe, nil}}
      end)

    # Falco flees; ness holds the charge `hold` more frames, then
    # releases with nobody in range.
    {probe, swing_hit?} =
      Enum.reduce(1..(hold + 50), {probe, false}, fn i, {probe, swing_hit?} ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, walk_out, 0.5)
        if i == hold, do: Melee.Controller.release_button(probe.controllers[1], :a)
        if i == hold + 1, do: Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 0.5)
        probe = Probe.step!(probe)
        falco = Probe.gamestate(probe).players[2]
        {probe, swing_hit? or (i > hold and falco.hitlag_left > 0)}
      end)

    IO.puts("[dolphin]   arm: charge_hit_at=#{inspect(hit_at)} swing_hit=#{swing_hit?}")
    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])
    settle_ports(probe, [1, 2])
  end

  defp jacket_round(probe, arm) do
    probe = settle_ports(probe, [1, 2])
    probe = center_at(probe, 0.0)

    probe = if arm != nil, do: arm_yoyo(probe, arm), else: probe

    # Falco parks 35 out on HIS OWN side (walking through ness would
    # bulldoze him off his mark), ness re-centers facing right — the
    # climb keeps the whole loop above the floor, so mid-stage works.
    ness_x = player(probe).position.x
    fx0 = Probe.gamestate(probe).players[2].position.x

    probe =
      if fx0 > ness_x do
        walk_port(probe, 2, 0.72, fn p -> p.position.x > ness_x + 35.0 end)
      else
        walk_port(probe, 2, 0.28, fn p -> p.position.x < ness_x - 35.0 end)
      end

    probe = settle_ports(probe, [1, 2])
    probe = center_at(probe, 0.0)

    probe =
      Enum.reduce(1..2, probe, fn _i, probe ->
        Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.7, 0.5)
        Probe.step!(probe)
      end)

    probe = settle_ports(probe, [1, 2])

    # PKT2 into his own side: climb `u` frames, then a 270-degree
    # loop over the offstage air (quarter turn = 15 frames at
    # 6 deg/frame, radius ~19) exits moving LEFT at height 2u - 11
    # relative to the cast — straight into ness. A full 360 loop only
    # GRAZES its own spawn point (measured), so the climb is what
    # aims the horizontal pass at his torso; sweep it.
    {probe, pkt2?} =
      Enum.reduce_while([11, 12, 10, 13], {probe, false}, fn u, {probe, _} ->
        {probe, hit?} =
          run_tech(
            probe,
            Tech.new(:pkt2, :ness,
              steer: [
                {0.5, 1.0, u},
                {1.0, 0.5, 17},
                {0.5, 0.0, 17},
                {0.0, 0.5, 17},
                {0.0, 0.5, 45}
              ]
            ),
            240,
            fn hit, p -> hit or p.hitlag_left > 0 end,
            false
          )

        probe = settle_ports(probe, [1, 2])
        probe = center_at(probe, 81.0)

        if hit?, do: {:halt, {probe, true}}, else: {:cont, {probe, false}}
      end)

    probe = settle_ports(probe, [1, 2])

    # The probe: falco walks INTO ness for 80 frames; ness holds
    # still. Contact damage with ness idle = the jacket.
    ness_x = player(probe).position.x
    fx = Probe.gamestate(probe).players[2].position.x
    pct0 = Probe.gamestate(probe).players[2].percent
    walk_in = if fx > ness_x, do: 0.28, else: 0.72

    {probe, ness_attacked?} =
      Enum.reduce(1..80, {probe, false}, fn _i, {probe, atk} ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, walk_in, 0.5)
        probe = Probe.step!(probe)
        ness = player(probe)
        {probe, atk or (ness.action >= 0x2C and ness.action < 0x140)}
      end)

    Melee.Controller.release_all(probe.controllers[2])
    dmg = Probe.gamestate(probe).players[2].percent - pct0
    probe = settle_ports(probe, [1, 2])

    {probe,
     %{
       pkt2?: pkt2?,
       jacket?: dmg > 0.0 and not ness_attacked?,
       dmg: Float.round(dmg * 1.0, 1),
       ness_attacked?: ness_attacked?
     }}
  end

  # One yo-yo round: falco walks into the held charge, parks after the
  # first hit; every hit is logged with distance and ness's action.
  defp yoyo_round(probe) do
    probe = settle_ports(probe, [1, 2])

    # Recenter if the knockbacks pushed the scene toward an edge.
    fx = Probe.gamestate(probe).players[2].position.x

    probe =
      if abs(fx) > 40.0 do
        probe =
          walk_port(probe, 2, if(fx > 0, do: 0.28, else: 0.72), fn p ->
            abs(p.position.x) < 20.0
          end)

        settle_ports(probe, [1, 2])
      else
        probe
      end

    falco_x = Probe.gamestate(probe).players[2].position.x
    me_x = player(probe).position.x
    tilt = if falco_x > me_x, do: 0.72, else: 0.28
    probe = walk_until(probe, tilt, fn p -> abs(p.position.x - falco_x) < 16.0 end)
    probe = settle_ports(probe, [1, 2])

    walk_in = if falco_x > player(probe).position.x, do: 0.28, else: 0.72

    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 1.0)
    Melee.Controller.press_button(probe.controllers[1], :a)

    {probe, hits} =
      Enum.reduce(1..140, {probe, []}, fn i, {probe, hits} ->
        # Falco HOLDS toward throughout - exactly the mapped run where
        # the ranged re-hit appeared (the held direction shapes the
        # knockback path).
        Melee.Controller.tilt_analog(probe.controllers[2], :main, walk_in, 0.5)
        probe = Probe.step!(probe)
        gs = Probe.gamestate(probe)
        a = gs.players[1]
        b = gs.players[2]
        prev = List.first(hits)

        hits =
          if b.hitlag_left > 0 and (prev == nil or b.percent > elem(prev, 0)) do
            [{b.percent, Float.round(abs(b.position.x - a.position.x), 1), a.action, i} | hits]
          else
            hits
          end

        {probe, hits}
      end)

    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])
    {probe, Enum.reverse(hits)}
  end

  ## thunder jacket: the ledge-grab interrupt ---------------------------

  # PROVEN 2026-08-21 (mapped in tmp/jacket_ledgegrab_probe.exs). The
  # full recipe, all headless:
  #
  #   1. ARM: ness charges usmash facing falco ~15 out; falco walks in
  #      and takes the WINDUP hit (charge frame 11-12, reach ~10 — the
  #      yo-yo dangles in FRONT; point-blank whiffs); falco DASHES
  #      clear (the release swing reaches ~14 for 36 frames — a walk
  #      cannot escape it); ness releases 11-16 frames AFTER the hit
  #      (<=10 and >=18 do NOT arm — a ~6-frame window, the charge
  #      pulse period) with the swing hitting nothing.
  #   2. INTERRUPT: PKT2 that ends in a LEDGE GRAB. From a right-ledge
  #      hang (facing the stage), release at CliffWait — the catch
  #      anim is input-immune — fall 12 frames, cast, hold down 12
  #      frames, then steer right/down/dive-24/curl-up-left: the bolt
  #      comes up under ness, the launch grazes FD's underside (0x16E)
  #      and CliffCatches. Post-PKT2 fall is FallSpecial — no DJ
  #      exists, which is why every non-grabbing variant died.
  #   3. THE ZAP: the stored usmash hitbox ends up PARKED AT THE
  #      LEDGE — the point where the PKT2 was interrupted (~(96, -4)
  #      on FD's right ledge) — not riding ness: contact with idle
  #      ness mid-stage reads ZERO, while falco reaching the lip zone
  #      gets zapped for the stored hit's damage (up to ~20%; distant
  #      grazes read 1%), once — consumed on first touch, and gone.
  #      A platform-landing interrupt (BF, tmp/jacket_bf_probe.exs)
  #      does NOT arm it — the ledge grab is the real method, as the
  #      user said.

  test "thunder jacket: armed yo-yo + PKT2 ledge-grab interrupt zaps (1%)", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_115, :ness)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle_ports(probe, [1, 2])
        probe = tj_park(probe, 2, -40.0)

        # Control: UNARMED PKT2 ledge grab, then the same contact
        # probes — must read zero.
        {probe, ctl_grab?, ctl} = tj_round(probe, false)
        IO.puts("\n[dolphin] jacket control: grab=#{ctl_grab?} #{inspect(ctl)}")

        # Armed: the full recipe.
        {probe, grab?, res} = tj_round(probe, true)
        IO.puts("[dolphin] jacket armed: grab=#{grab?} #{inspect(res)}")

        assert ctl_grab?
        assert ctl.hop_dmg == 0.0 and ctl.lip_dmg == 0.0
        assert grab?
        assert res.hop_dmg >= 1.0
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  # One jacket round: optionally arm, PKT2 into the right-ledge grab,
  # then the contact probes (lip walk-in + hop-on from above).
  defp tj_round(probe, armed?) do
    probe = if armed?, do: tj_arm(probe), else: probe
    {probe, grab?} = tj_pkt2_ledge_grab(probe)

    if grab? do
      {probe, res} = tj_ledge_probe(probe)
      {probe, true, res}
    else
      {settle_ports(probe, [1, 2]), false, %{lip_dmg: 0.0, hop_dmg: 0.0}}
    end
  end

  # The arming: windup hit -> dash clear -> release at hit+12. The
  # windup hit is position-marginal (falco's park tolerance), so retry
  # until it lands CLEAN: hit at the windup (frame <= 14), swing whiff.
  defp tj_arm(probe), do: tj_arm(probe, 4)

  defp tj_arm(probe, tries) do
    probe = tj_park(probe, 1, -5.0)
    probe = tj_park(probe, 2, 26.0)
    probe = walk_port(probe, 1, 0.72, fn p -> p.position.x > 10.2 end)
    probe = settle_ports(probe, [1])

    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 1.0)
    Melee.Controller.press_button(probe.controllers[1], :a)

    {probe, hit_at} =
      Enum.reduce_while(1..60, {probe, nil}, fn i, {probe, _} ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, 0.28, 0.5)
        probe = Probe.step!(probe)
        falco = Probe.gamestate(probe).players[2]
        if falco.hitlag_left > 0, do: {:halt, {probe, i}}, else: {:cont, {probe, nil}}
      end)

    probe =
      Enum.reduce(1..12, probe, fn _i, probe ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, 1.0, 0.5)
        Probe.step!(probe)
      end)

    Melee.Controller.release_button(probe.controllers[1], :a)
    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 0.5)

    {probe, swing_hit?} =
      Enum.reduce(1..45, {probe, false}, fn _i, {probe, sh?} ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, 1.0, 0.5)
        probe = Probe.step!(probe)
        falco = Probe.gamestate(probe).players[2]
        {probe, sh? or falco.hitlag_left > 0}
      end)

    IO.puts("[dolphin]   arm: charge_hit_at=#{inspect(hit_at)} swing_hit=#{swing_hit?}")
    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])
    probe = settle_ports(probe, [1, 2])
    clean? = hit_at != nil and hit_at <= 14 and not swing_hit?

    if clean? or tries <= 1, do: probe, else: tj_arm(probe, tries - 1)
  end

  # Hang the right ledge (hop out facing LEFT, hug in), release at
  # CliffWait, cast falling, dive-and-curl the bolt into the up-launch
  # whose flight CliffCatches. Constants from the probe map: 12 fall
  # frames, 12 down-hold, dive 24.
  defp tj_pkt2_ledge_grab(probe) do
    {probe, hung?} = tj_hang_right(probe)

    if hung?,
      do: tj_release_cast_steer(probe),
      else: {settle_ports(probe, [1, 2]), false}
  end

  # Release the hang (CliffWait only — the catch anim is input-
  # immune), fall 12 frames, cast, hold down 12, then steer.
  defp tj_release_cast_steer(probe) do
    probe =
      Probe.until!(
        probe,
        fn p -> Probe.gamestate(p).players[1].action == 0xFD end,
        fn p ->
          Melee.Controller.release_all(p.controllers[1])
          p
        end,
        timeout_frames: 90
      )

    {probe, _released?} =
      Enum.reduce_while(1..8, {probe, false}, fn _i, {probe, _} ->
        Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 0.0)
        probe = Probe.step!(probe)

        if player(probe).action in [0xFC, 0xFD],
          do: {:cont, {probe, false}},
          else: {:halt, {probe, true}}
      end)

    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 0.5)
    probe = Enum.reduce(1..12, probe, fn _i, probe -> Probe.step!(probe) end)

    Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 1.0)
    Melee.Controller.press_button(probe.controllers[1], :b)
    probe = Probe.step!(probe)
    Melee.Controller.release_button(probe.controllers[1], :b)

    probe =
      Enum.reduce(1..12, probe, fn _i, probe ->
        Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.5, 0.0)
        Probe.step!(probe)
      end)

    plan = [{1.0, 0.5, 15}, {0.5, 0.0, 15}, {0.5, 0.0, 24}, {0.15, 0.85, 60}]
    {probe, grab?} = tj_steer(probe, plan)
    Melee.Controller.release_all(probe.controllers[1])
    {probe, grab?}
  end

  # Walk the steer plan; on the flight's wall graze or special fall,
  # switch to a stage-ward hug. Returns whether the flight grabbed.
  defp tj_steer(probe, plan) do
    Enum.reduce_while(1..320, {probe, {plan, 0, false, false}}, fn _i, {probe, st} ->
      {plan, c, pkt2?, hugging?} = st
      {plan, c} = tj_steer_input(probe, plan, c, hugging?)

      probe = Probe.step!(probe)
      pl = player(probe)
      pkt2? = pkt2? or pl.action == 0x16D
      hugging? = hugging? or pl.action == 0x16E or (pkt2? and pl.action == 0x23)

      cond do
        pkt2? and pl.action in [0xFC, 0xFD] -> {:halt, {probe, true}}
        pl.action in [0x0C, 0x00] or (pkt2? and pl.on_ground) -> {:halt, {probe, false}}
        true -> {:cont, {probe, {plan, c, pkt2?, hugging?}}}
      end
    end)
    |> case do
      {probe, grab?} when is_boolean(grab?) -> {probe, grab?}
      {probe, _st} -> {probe, false}
    end
  end

  defp tj_steer_input(probe, plan, c, hugging?) do
    cond do
      hugging? ->
        Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.25, 0.5)
        {plan, c}

      plan != [] ->
        [{x, y, frames} | rest] = plan
        Melee.Controller.tilt_analog(probe.controllers[1], :main, x, y)
        if c + 1 >= frames, do: {rest, 0}, else: {plan, c + 1}

      true ->
        {plan, c}
    end
  end

  defp tj_hang_right(probe) do
    probe = tj_park(probe, 1, 78.0)

    # Face LEFT (into the stage) so the falls beside the ledge grab it.
    probe =
      Enum.reduce_while(1..20, probe, fn _i, probe ->
        if player(probe).facing do
          Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.3, 0.5)
          {:cont, Probe.step!(probe)}
        else
          {:halt, probe}
        end
      end)

    probe = settle_ports(probe, [1])

    # Full hop, breaking out the moment he lifts off (running the
    # routine to :done would land him again before the drift).
    {probe, _tech} =
      Enum.reduce_while(1..30, {probe, Tech.new(:full_hop, :ness)}, fn _i, {probe, tech} ->
        {_s, tech} = Tech.step(tech, player(probe), probe.controllers[1])
        probe = Probe.step!(probe)
        if player(probe).on_ground, do: {:cont, {probe, tech}}, else: {:halt, {probe, tech}}
      end)

    probe =
      Probe.until!(
        probe,
        fn p ->
          pl = Probe.gamestate(p).players[1]
          pl.position.x > 87.0 or pl.on_ground
        end,
        fn p ->
          Melee.Controller.tilt_analog(p.controllers[1], :main, 0.85, 0.5)
          p
        end,
        timeout_frames: 120
      )

    {probe, hung?} =
      Enum.reduce_while(1..150, {probe, false}, fn _i, {probe, _} ->
        Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.3, 0.5)
        probe = Probe.step!(probe)
        pl = player(probe)

        cond do
          pl.action == 0xFC -> {:halt, {probe, true}}
          pl.on_ground -> {:halt, {probe, false}}
          true -> {:cont, {probe, false}}
        end
      end)

    Melee.Controller.release_all(probe.controllers[1])
    if hung?, do: {probe, true}, else: {settle_ports(probe, [1]), false}
  end

  # After the grab: ness climbs (ledge jump, lands ~66), then falco
  # probes. Contact with ness on the way reads ZERO even armed — the
  # stored hitbox is NOT on ness: it is PARKED AT THE LEDGE, where the
  # PKT2 was interrupted. Walking into the lip zone (teeter) and/or
  # hopping out past the ledge point (~(96, -4)) collects the zap when
  # armed — up to ~20%, once; unarmed, nothing anywhere.
  defp tj_ledge_probe(probe) do
    probe = tj_park(probe, 2, 55.0)

    probe =
      Probe.until!(
        probe,
        fn p ->
          pl = Probe.gamestate(p).players[1]
          pl.on_ground and pl.action not in [0xFC, 0xFD]
        end,
        fn p ->
          if Probe.gamestate(p).players[1].action == 0xFD,
            do: Melee.Controller.press_button(p.controllers[1], :y)

          p
        end,
        timeout_frames: 240
      )

    Melee.Controller.release_all(probe.controllers[1])
    pct0 = Probe.gamestate(probe).players[2].percent

    # Ground contact with ness first (the negative: ness carries no
    # hitbox) — falco walks right THROUGH ness's landing spot to the
    # lip, stopping at the teeter.
    {probe, lip_dmg} =
      Enum.reduce_while(1..90, {probe, 0.0}, fn _i, {probe, hit} ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, 0.72, 0.5)
        probe = Probe.step!(probe)
        f = Probe.gamestate(probe).players[2]
        hit = max(hit, f.percent - pct0)

        if f.action in [0xF5, 0xF6],
          do: {:halt, {probe, hit}},
          else: {:cont, {probe, hit}}
      end)

    # The ledge-point probe: hop off the lip with slight outward
    # drift; the arc falls just past the ledge — through the parked
    # hitbox when armed. Watch the whole fall.
    {probe, hop_dmg} =
      Enum.reduce(1..80, {probe, 0.0}, fn i, {probe, hit} ->
        if i <= 5, do: Melee.Controller.press_button(probe.controllers[2], :y)
        if i == 6, do: Melee.Controller.release_button(probe.controllers[2], :y)
        Melee.Controller.tilt_analog(probe.controllers[2], :main, 0.66, 0.5)
        probe = Probe.step!(probe)
        {probe, max(hit, Probe.gamestate(probe).players[2].percent - pct0)}
      end)

    Melee.Controller.release_all(probe.controllers[2])
    probe = settle_ports(probe, [1, 2])

    {probe, %{lip_dmg: Float.round(lip_dmg, 1), hop_dmg: Float.round(hop_dmg, 1)}}
  end

  defp tj_park(probe, port, x) do
    probe = settle_ports(probe, [port])
    px = Probe.gamestate(probe).players[port].position.x

    probe =
      cond do
        px > x + 3.0 -> walk_port(probe, port, 0.28, fn p -> p.position.x < x + 2.0 end)
        px < x - 3.0 -> walk_port(probe, port, 0.72, fn p -> p.position.x > x - 2.0 end)
        true -> probe
      end

    settle_ports(probe, [port])
  end
end
