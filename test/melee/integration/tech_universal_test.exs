defmodule Melee.Integration.TechUniversalTest do
  use ExUnit.Case

  @moduledoc """
  The universal-batch routines proven live: JC grab (a STANDING catch
  out of a dash), moonwalk (backward slide inside the dash animation),
  fox trot (re-dashes that never mature into a run), crouch cancel
  (A/B knockback peak vs a control hit), wavedash out of shield,
  shine turnaround, drillshine, powershield (a timed press against a
  tracked falco laser), plus shield drop (Battlefield platforms) and
  Falco's SH double laser.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_universal
  """

  alias Melee.{Enums, Probe, Tech}

  @moduletag :dolphin
  @moduletag :dolphin_universal
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_universal_it")

  @dashing 0x14
  @running 0x15
  @knee_bend 0x18
  @catch_standing 0xD4
  @shield_reflect 0xB6
  @platform_drop 0xF4
  @shine_states [Enums.Action.to_id(:down_b_ground_start), Enums.Action.to_id(:down_b_ground)]

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

  test "the universal batch on FD: trot, moonwalk, OOS, shines, JC grab, CC, powershield", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_081, :fox, :final_destination)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle_both(probe)

        # --- Fox trot: 3 initial-dash starts, never a run.
        probe = center_fox(probe)
        {probe, {starts, ran?}} = fox_trot(probe)
        IO.puts("\n[dolphin] fox trot: #{starts} dash starts, entered run: #{ran?}")
        assert starts >= 3
        refute ran?

        # --- Moonwalk: the down-back park kills the dash's velocity
        # (fox can't net-reverse a standing start in one dash — the
        # proof is the A/B against a stick-held control dash).
        probe = center_fox(probe)
        {probe, control_speed} = dash_end_speed(probe, :control)
        probe = center_fox(probe)
        {probe, {flip?, moon_speed}} = moonwalk(probe)

        IO.puts(
          "[dolphin] moonwalk: dash-end speed #{Float.round(moon_speed, 2)} vs control #{Float.round(control_speed, 2)} u/f, facing_flipped=#{flip?}"
        )

        refute flip?
        assert control_speed > 0.8
        assert moon_speed < control_speed * 0.35

        # --- Wavedash out of shield.
        probe = settle_both(probe)

        {probe, {shielded?, landed?}} =
          run_tech(
            probe,
            Tech.new(:wavedash_oos, :fox, direction: :left),
            90,
            fn {s, l}, p ->
              {s or p.action in [178, 179], l or p.action == Enums.Action.to_id(:landing_special)}
            end,
            {false, false}
          )

        IO.puts("[dolphin] wavedash OOS: shield=#{shielded?} special_landing=#{landed?}")
        assert shielded?
        assert landed?

        # --- Shine turnaround.
        probe = settle_both(probe)
        f0 = player(probe, 1).facing

        {probe, flipped_in_shine?} =
          run_tech(
            probe,
            Tech.new(:shine_turnaround, :fox),
            60,
            # 0x168..0x16C is the grounded shine family — the flip
            # lands in 0x16C, the shine-turn state.
            fn acc, p -> acc or (p.action in 0x168..0x16C and p.facing != f0) end,
            false
          )

        IO.puts("[dolphin] shine turnaround: flipped_in_shine=#{flipped_in_shine?}")
        assert flipped_in_shine?

        # --- Drillshine: dair, then the shine out of the landing.
        probe = settle_both(probe)

        {probe, {dair?, land_frame, shine_frame, _n}} =
          run_tech(
            probe,
            Tech.new(:drillshine, :fox),
            120,
            fn {d, lf, sf, n}, p ->
              d = d or p.action == Enums.Action.to_id(:dair)
              lf = lf || if(p.action == Enums.Action.to_id(:dair_landing), do: n)
              sf = sf || if(p.action in @shine_states, do: n)
              {d, lf, sf, n + 1}
            end,
            {false, nil, nil, 0}
          )

        gap = if land_frame && shine_frame, do: shine_frame - land_frame

        IO.puts("[dolphin] drillshine: dair=#{dair?} landing->shine gap=#{inspect(gap)} frames")
        assert dair?
        assert gap != nil and gap <= 12

        # --- JC grab: dash in, Z in jumpsquat -> STANDING catch.
        probe = settle_both(probe)
        probe = approach_falco(probe, 9.0)
        {probe, {squat?, catch?}} = jc_grab(probe)
        IO.puts("[dolphin] jc grab: jumpsquat=#{squat?} standing_catch=#{catch?}")
        assert squat?
        assert catch?
        probe = wait_grab_release(probe)

        # --- Crouch cancel: falco dash-attacks; control peak vs CC peak.
        # Re-center first — the grab chase can end at the edge, where
        # falco's launcher positioning would walk off the stage.
        probe = center_fox(probe)
        # One warmup hit first so the control launch (at ~10%) clearly
        # lifts off; the CC arm runs at HIGHER percent, so the
        # assertion direction is conservative.
        probe = settle_both(probe)
        {probe, _warmup} = dash_attack_peak(probe, nil)
        probe = settle_both(probe)
        {probe, control_peak} = dash_attack_peak(probe, nil)
        probe = settle_both(probe)
        {probe, cc_peak} = dash_attack_peak(probe, Tech.new(:crouch_cancel, :fox))

        IO.puts(
          "[dolphin] crouch cancel: control_peak=#{Float.round(control_peak, 2)} cc_peak=#{Float.round(cc_peak, 2)} (cc at HIGHER percent)"
        )

        assert control_peak > 1.0
        assert cc_peak < control_peak * 0.6

        # --- Powershield a falco laser.
        probe = center_fox(probe)
        {probe, ps?} = powershield_laser(probe)
        IO.puts("[dolphin] powershield: GuardReflect=#{ps?}")
        assert ps?

        # --- Shine grab: shine, jump-cancel, Z in jumpsquat. The
        # shined falco slides out of range, so the proof is the input
        # chain: shine -> knee_bend -> Catch (0xD4).
        probe = settle_both(probe)
        probe = approach_falco(probe, 7.0)

        {probe, {shined?, sg_squat?, sg_catch?}} =
          run_tech(
            probe,
            Tech.new(:shine_grab, :fox),
            60,
            fn {s, q, c}, p ->
              {s or p.action in @shine_states, q or p.action == @knee_bend,
               c or p.action == @catch_standing}
            end,
            {false, false, false}
          )

        IO.puts(
          "[dolphin] shine grab: shine=#{shined?} jumpsquat=#{sg_squat?} catch=#{sg_catch?}"
        )

        assert shined?
        assert sg_squat?
        assert sg_catch?

        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Yoshi parry: the timed shield press against a falco laser", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_087, :yoshi, :final_destination)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle_both(probe)

        # Yoshi's shield is NOT the standard 178..180 family — the egg
        # lives in the special range (0x156 hold, 0x159 release,
        # discovered by trace), it never GuardReflects, and the
        # `invulnerable` flag stays false. What we CAN pin: the egg
        # states, and a laser crossing his position with zero damage
        # and zero stun — parry-consistent (full parry detection needs
        # hitbox-level data; see docs/melee-tech.md).
        me_x = player(probe, 1).position.x
        {probe, {egg?, crossed?, stunned?, trace}} = yoshi_egg_laser(probe, me_x)
        pct = player(probe, 1).percent

        IO.puts(
          "\n[dolphin] yoshi egg vs laser: egg_states=#{egg?} laser_crossed=#{crossed?} stunned=#{stunned?} percent=#{pct} trace=#{inspect(Enum.take(trace, 6), base: :hex)}"
        )

        assert egg?
        assert crossed?
        assert pct == 0.0
        refute stunned?
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "shield drop through a Battlefield platform", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_083, :fox, :battlefield)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # Get onto the LEFT side platform (y = 27.2) — falco spawns on
        # the right and body-blocks a rightward walk. Stand under it,
        # full hop up through it, land on top.
        probe = walk_until(probe, 0.28, fn p -> p.position.x < -38.0 end)
        probe = settle(probe)
        {probe, _} = run_tech(probe, Tech.new(:full_hop, :fox), 30, fn a, _ -> a end, nil)

        probe =
          Probe.until!(
            probe,
            fn p ->
              pl = Probe.gamestate(p).players[1]
              pl != nil and pl.on_ground and pl.position.y > 20.0
            end,
            fn p -> p end,
            timeout_frames: 120
          )

        p0 = player(probe, 1)
        IO.puts("\n[dolphin] on platform at (#{r(p0.position.x)}, #{r(p0.position.y)})")

        {probe, {dropped?, min_y}} =
          run_tech(
            probe,
            Tech.new(:shield_drop, :fox),
            60,
            fn {d, my}, p ->
              {d or p.action == @platform_drop or (not p.on_ground and p.position.y < 26.0),
               min(my, p.position.y)}
            end,
            {false, 100.0}
          )

        # Let the fall land.
        {probe, min_y} =
          Enum.reduce(1..40, {probe, min_y}, fn _i, {probe, my} ->
            probe = Probe.step!(probe)
            p = Probe.gamestate(probe).players[1]
            {probe, min(my, p.position.y)}
          end)

        IO.puts("[dolphin] shield drop: dropped=#{dropped?} min_y=#{r(min_y)}")
        assert dropped?
        assert min_y < 5.0

        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Falco short-hop double laser", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_085, :falco, :final_destination)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # Count laser SPAWNS (projectile-count increases) during the
        # hop — the first laser can despawn before the second exists.
        tech = Tech.new(:double_laser, :falco)

        {probe, _tech, spawns, _prev} =
          Enum.reduce_while(1..90, {probe, tech, 0, 0}, fn _i, {probe, tech, spawns, prev} ->
            pl = Probe.gamestate(probe).players[1]
            {status, tech} = Tech.step(tech, pl, probe.controllers[1])
            probe = Probe.step!(probe)
            n = length(Probe.gamestate(probe).projectiles)
            spawns = if n > prev, do: spawns + (n - prev), else: spawns

            if status == :done,
              do: {:halt, {probe, tech, spawns, n}},
              else: {:cont, {probe, tech, spawns, n}}
          end)

        IO.puts("\n[dolphin] double laser: lasers spawned in one short hop=#{spawns}")
        assert spawns >= 2

        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  ## drivers -----------------------------------------------------------

  defp boot(ctx, port, character, stage) do
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

    p1 = [port: 1, character: Enums.Character.to_id(character), stage: Enums.Stage.to_id(stage)]
    p2 = [port: 2, character: Enums.Character.to_id(:falco), stage: Enums.Stage.to_id(stage)]

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

  defp r(v), do: Float.round(v * 1.0, 1)

  defp player(probe, port), do: Probe.gamestate(probe).players[port]

  defp run_tech(probe, tech, budget, fold, acc0) do
    Enum.reduce_while(1..budget, {probe, tech, acc0}, fn _i, {probe, tech, acc} ->
      pl = Probe.gamestate(probe).players[1]
      {status, tech} = Tech.step(tech, pl, probe.controllers[1])
      probe = Probe.step!(probe)
      acc = fold.(acc, Probe.gamestate(probe).players[1])

      if status == :done, do: {:halt, {probe, acc}}, else: {:cont, {probe, tech, acc}}
    end)
    |> case do
      {probe, acc} -> {probe, acc}
      {probe, _tech, acc} -> {probe, acc}
    end
  end

  defp settle(probe), do: settle_port(probe, [1])
  defp settle_both(probe), do: settle_port(probe, [1, 2])

  defp settle_port(probe, ports) do
    Enum.each(ports, &Melee.Controller.release_all(probe.controllers[&1]))

    Probe.until!(
      probe,
      fn p ->
        Enum.all?(ports, fn port ->
          pl = Probe.gamestate(p).players[port]
          # STANDING specifically — walks (0x0F..0x11) also sit below
          # 0x40 and poison smash-input starts.
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

  # Fox near center; falco parked out of the way on the right.
  defp center_fox(probe) do
    probe = settle_both(probe)
    fox = player(probe, 1)

    probe =
      cond do
        fox.position.x > 15.0 -> walk_until(probe, 0.28, fn p -> p.position.x < 5.0 end)
        fox.position.x < -15.0 -> walk_until(probe, 0.72, fn p -> p.position.x > -5.0 end)
        true -> probe
      end

    settle_both(probe)
  end

  defp fox_trot(probe) do
    tech = Tech.new(:fox_trot, :fox, direction: :left, reps: 3, dash_frames: 7)

    run_tech(
      probe,
      tech,
      120,
      fn {starts, ran, prev_af, tr}, p ->
        starts =
          if p.action == @dashing and p.action_frame <= 1.5 and
               (prev_af == nil or p.action_frame < prev_af),
             do: starts + 1,
             else: starts

        {starts, ran or p.action == @running,
         if(p.action == @dashing, do: p.action_frame, else: nil),
         [{p.action, trunc(p.action_frame)} | tr]}
      end,
      {0, false, nil, []}
    )
    |> then(fn {probe, {starts, ran, _, _tr}} -> {probe, {starts, ran}} end)
  end

  # Average |dx| over the last 3 observed DASH frames.
  defp dash_end_speed_from(positions) do
    case positions do
      [a, b, c, d | _] -> (abs(a - b) + abs(b - c) + abs(c - d)) / 3
      _ -> 0.0
    end
  end

  # Control arm: dash with the stick held full-forward through the
  # dash window; speed stays at dash speed.
  defp dash_end_speed(probe, :control) do
    f0 = player(probe, 1).facing
    x = if f0, do: 1.0, else: 0.0

    {probe, positions} =
      Enum.reduce(1..19, {probe, []}, fn _i, {probe, acc} ->
        Melee.Controller.tilt_analog(probe.controllers[1], :main, x, 0.5)
        probe = Probe.step!(probe)
        p = Probe.gamestate(probe).players[1]
        acc = if p.action == @dashing, do: [p.position.x | acc], else: acc
        {probe, acc}
      end)

    Melee.Controller.release_all(probe.controllers[1])
    {probe, dash_end_speed_from(positions)}
  end

  defp moonwalk(probe) do
    # Dash the way fox already faces — a cross-facing dash would flip
    # the facing on its own and poison the no-turn assertion.
    f0 = player(probe, 1).facing
    dir = if f0, do: :right, else: :left
    tech = Tech.new(:moonwalk, :fox, direction: dir, dash_frames: 1, slide_frames: 17)

    {probe, {flip, positions}} =
      run_tech(
        probe,
        tech,
        90,
        fn {flip, acc}, p ->
          flip = flip or p.facing != f0
          acc = if p.action == @dashing, do: [p.position.x | acc], else: acc
          {flip, acc}
        end,
        {false, []}
      )

    {probe, {flip, dash_end_speed_from(positions)}}
  end

  defp approach_falco(probe, range) do
    probe = settle_both(probe)
    falco_x = player(probe, 2).position.x

    walk_until(probe, if(falco_x > player(probe, 1).position.x, do: 0.72, else: 0.28), fn p ->
      abs(p.position.x - falco_x) < range + 4.0
    end)
    |> settle_both()
  end

  defp jc_grab(probe) do
    fox = player(probe, 1)
    falco_x = player(probe, 2).position.x
    toward = if falco_x > fox.position.x, do: :right, else: :left
    x = if toward == :right, do: 1.0, else: 0.0

    # Enter a dash toward falco first — the point is a standing catch
    # OUT OF the dash.
    probe =
      Enum.reduce(1..4, probe, fn _i, probe ->
        Melee.Controller.tilt_analog(probe.controllers[1], :main, x, 0.5)
        Probe.step!(probe)
      end)

    run_tech(
      probe,
      Tech.new(:jc_grab, :fox),
      40,
      fn {squat, caught}, p ->
        {squat or p.action == @knee_bend, caught or p.action == @catch_standing}
      end,
      {false, false}
    )
  end

  defp wait_grab_release(probe) do
    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])

    Probe.until!(
      probe,
      fn p ->
        a = Probe.gamestate(p).players[1]
        b = Probe.gamestate(p).players[2]
        a != nil and b != nil and a.action < 0x40 and b.action < 0x40 and a.on_ground
      end,
      fn p ->
        Melee.Controller.release_all(p.controllers[1])
        Melee.Controller.release_all(p.controllers[2])
        p
      end,
      timeout_frames: 900
    )
  end

  # Falco walks up and DTILTS fox (a dash attack sails over a crouched
  # fox); fox runs `tech` (or nothing). Returns fox's peak height
  # inside 30 frames after the hitlag ends.
  defp dash_attack_peak(probe, tech, attempts \\ 3) do
    probe = settle_both(probe)

    # Stand falco ~10 from fox on the right (dtilt range is short).
    fox_x = player(probe, 1).position.x

    probe =
      walk_port(
        probe,
        2,
        if(player(probe, 2).position.x > fox_x + 11.0, do: 0.28, else: 0.72),
        fn p ->
          abs(p.position.x - fox_x) < 11.0 and p.position.x > fox_x
        end
      )

    # A few leftward steps so falco FACES fox (the walk into position
    # may have been rightward), then settle.
    probe =
      Enum.reduce(1..3, probe, fn _i, probe ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, 0.3, 0.5)
        Probe.step!(probe)
      end)

    probe = settle_both(probe)

    # Crouch, then dtilt (A while holding down).
    probe =
      Enum.reduce(1..4, probe, fn _i, probe ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, 0.5, 0.05)
        Probe.step!(probe)
      end)

    Melee.Controller.press_button(probe.controllers[2], :a)
    probe = Probe.step!(probe)
    Melee.Controller.release_button(probe.controllers[2], :a)

    {probe, hit?, peak} = track_launch_peak(probe, tech)
    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])

    cond do
      hit? -> {probe, peak}
      attempts > 1 -> dash_attack_peak(probe, tech, attempts - 1)
      true -> {probe, -1.0}
    end
  end

  # Falco SH-lasers from the right; fox presses R with `lead` frames
  # to impact. Retries with different leads until GuardReflect.
  defp powershield_laser(probe) do
    Enum.reduce_while([2, 3, 1, 4, 0], {probe, false}, fn lead, {probe, _} ->
      {probe, ps?} = powershield_attempt(probe, lead)
      if ps?, do: {:halt, {probe, true}}, else: {:cont, {probe, false}}
    end)
  end

  defp powershield_attempt(probe, lead) do
    probe = settle_both(probe)

    # Fox to the left, falco ~45 away facing left (walk left to set
    # the facing, then settle).
    fox_x = player(probe, 1).position.x

    probe =
      walk_port(
        probe,
        2,
        if(player(probe, 2).position.x > fox_x + 46.0, do: 0.28, else: 0.72),
        fn p ->
          abs(p.position.x - (fox_x + 45.0)) < 6.0
        end
      )

    # Force a leftward step so falco FACES fox — a rightward walk into
    # position leaves him lasering the wrong way.
    probe =
      Enum.reduce(1..3, probe, fn _i, probe ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, 0.3, 0.5)
        Probe.step!(probe)
      end)

    probe = settle_both(probe)

    falco_tech = Tech.new(:short_hop_laser, :falco)

    {probe, seen} =
      Enum.reduce_while(1..120, {probe, falco_tech, nil, nil, false}, fn _i,
                                                                         {probe, ft, ps_tech,
                                                                          prev_lx, seen} ->
        gs = Probe.gamestate(probe)
        fox = gs.players[1]

        ft =
          if ft do
            {status, ft2} = Tech.step(ft, gs.players[2], probe.controllers[2])
            if status == :done, do: nil, else: ft2
          end

        laser = Enum.find(gs.projectiles, &(&1.position.x > fox.position.x))

        ps_tech = powershield_step(ps_tech, laser, prev_lx, fox, lead, probe.controllers[1])

        probe = Probe.step!(probe)
        fox = Probe.gamestate(probe).players[1]

        # Success is GuardReflect (0xB6) — or, for Yoshi, whose
        # powershield doesn't reflect, the parry: INTANGIBLE shield
        # startup as the laser arrives.
        seen =
          seen or fox.action == @shield_reflect or
            (fox.action in [178, 179] and fox.invulnerable)

        if seen do
          {:halt, {probe, true}}
        else
          {:cont, {probe, ft, ps_tech, laser && laser.position.x, seen}}
        end
      end)
      |> case do
        {probe, true} -> {probe, true}
        {probe, _ft, _ps, _lx, seen} -> {probe, seen}
      end

    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])
    {probe, seen}
  end

  # One falco SH laser at a shielding yoshi. Returns whether the egg
  # states appeared, whether the laser crossed yoshi's x, and whether
  # yoshi ever took stun.
  defp yoshi_egg_laser(probe, me_x) do
    probe = settle_both(probe)
    fox_x = player(probe, 1).position.x

    probe =
      walk_port(
        probe,
        2,
        if(player(probe, 2).position.x > fox_x + 46.0, do: 0.28, else: 0.72),
        fn p -> abs(p.position.x - (fox_x + 45.0)) < 6.0 end
      )

    probe =
      Enum.reduce(1..3, probe, fn _i, probe ->
        Melee.Controller.tilt_analog(probe.controllers[2], :main, 0.3, 0.5)
        Probe.step!(probe)
      end)

    probe = settle_both(probe)
    falco_tech = Tech.new(:short_hop_laser, :falco)

    # Shield the whole time; watch the laser cross.
    Melee.Controller.press_button(probe.controllers[1], :r)

    {probe, _ft, {egg, crossed, stunned, trace}} =
      Enum.reduce(1..70, {probe, falco_tech, {false, false, false, []}}, fn _i,
                                                                            {probe, ft,
                                                                             {egg, crossed,
                                                                              stunned, tr}} ->
        gs = Probe.gamestate(probe)

        ft =
          if ft do
            {status, ft2} = Tech.step(ft, gs.players[2], probe.controllers[2])
            if status == :done, do: nil, else: ft2
          end

        probe = Probe.step!(probe)
        gs = Probe.gamestate(probe)
        me = gs.players[1]
        laser = List.first(gs.projectiles)

        egg = egg or me.action in 0x155..0x15A
        crossed = crossed or (laser != nil and laser.position.x < me_x)
        stunned = stunned or me.hitlag_left > 0

        entry = {me.action, me.hitlag_left, laser && Float.round(laser.position.x, 0)}
        tr = if tr == [] or hd(tr) != entry, do: [entry | tr], else: tr
        {probe, ft, {egg, crossed, stunned, tr}}
      end)

    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])
    {settle_both(probe), {egg, crossed, stunned, Enum.reverse(trace)}}
  end

  # Advance an in-flight powershield, or arm one when the tracked
  # laser is `lead` frames from impact.
  defp powershield_step(ps_tech, laser, prev_lx, fox, lead, controller) do
    cond do
      ps_tech != nil ->
        step_optional(ps_tech, fox, controller)

      laser != nil and prev_lx != nil ->
        speed = prev_lx - laser.position.x

        if speed > 0.1 and (laser.position.x - fox.position.x - 4.0) / speed <= lead do
          step_optional(Tech.new(:powershield, :fox), fox, controller)
        end

      true ->
        nil
    end
  end

  defp track_launch_peak(probe, tech) do
    Enum.reduce_while(1..90, {probe, tech, :waiting, 0, 0.0}, fn _i,
                                                                 {probe, tech, phase, left, pk} ->
      fox = player(probe, 1)
      tech = step_optional(tech, fox, probe.controllers[1])
      probe = Probe.step!(probe)
      fox = player(probe, 1)
      launch_phase(probe, tech, phase, left, pk, fox)
    end)
    |> case do
      {probe, true, pk} -> {probe, true, pk}
      {probe, _tech, :waiting, _l, pk} -> {probe, false, pk}
      {probe, _tech, :hit, _l, pk} -> {probe, true, pk}
    end
  end

  defp step_optional(nil, _player, _controller), do: nil

  defp step_optional(tech, player, controller) do
    {_s, t2} = Tech.step(tech, player, controller)
    t2
  end

  defp launch_phase(probe, tech, :waiting, _left, pk, fox) do
    if fox.hitlag_left > 0,
      do: {:cont, {probe, tech, :hit, 30, pk}},
      else: {:cont, {probe, tech, :waiting, 0, pk}}
  end

  defp launch_phase(probe, tech, :hit, left, pk, fox) do
    cond do
      fox.hitlag_left > 0 -> {:cont, {probe, tech, :hit, 30, pk}}
      left > 0 -> {:cont, {probe, tech, :hit, left - 1, max(pk, fox.position.y)}}
      true -> {:halt, {probe, true, pk}}
    end
  end
end
