defmodule Melee.Integration.TechPoolTest do
  use ExUnit.Case

  @moduledoc """
  The feasible-unpicked pool, proven live: falco's phantasm +
  shortening (falco rides actions 0x15B-0x15D, NOT fox's illusion
  slots; the shorten at dash frame 14 cuts travel 60.5 -> 11.0), the
  ledge-cancelled phantasm off a BF platform edge, haxdash (ledge
  release -> instant DJ regrab with the intangibility REFRESHED),
  falco's ledgehop double laser, pivot grab, boost grab (the dash
  attack's slide carried into a grab: 25.1 vs the JC grab's 2.1),
  and Yoshi's double-jump armor (damaged mid-DJ but never enters a
  damage action).

  NOT here: the Marth up-B ledgestall — the dolphin slash's rise
  never ledge-grabbed in this rig (mapped from x 88.6 at y -7..-19,
  normal and B-reversed) — the refresh category is proven via
  haxdash; marth's snap conditions are a windowed follow-up.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_pool
  """

  alias Melee.{Enums, Probe, Tech}

  @moduletag :dolphin
  @moduletag :dolphin_pool
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_pool_it")

  @fd_lip 85.57
  @bf_left_inner_edge -20.0

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

  test "Illusion, full and shortened (falco phantasm)", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_131, :falco, :final_destination)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # Control: the full Illusion's travel.
        probe = center_at(probe, -40.0)
        x0 = player(probe).position.x

        {probe, trace} =
          run_tech(
            probe,
            Tech.new(:illusion, :falco, direction: :right),
            120,
            fn tr, p ->
              e = {p.action, trunc(p.action_frame)}
              if tr == [] or elem(hd(tr), 0) != p.action, do: [e | tr], else: tr
            end,
            []
          )

        probe = settle(probe)
        full_travel = player(probe).position.x - x0

        IO.puts(
          "\n[dolphin] full illusion travel=#{r(full_travel)} " <>
            "trace=#{inspect(Enum.reverse(trace), base: :hex, limit: 12)}"
        )

        # Shorten sweep: the second B press has its own action id.
        {probe, result} =
          Enum.reduce_while([:pulse, 6, 10, 14, 16, 18, 3], {probe, nil}, fn sf, {probe, _} ->
            probe = center_at(probe, -40.0)
            x1 = player(probe).position.x

            {probe, shortened?} =
              run_tech(
                probe,
                Tech.new(:illusion, :falco, direction: :right, shorten_frame: sf),
                120,
                fn s, p -> s or p.action in [0x160, 0x15D] end,
                false
              )

            probe = settle(probe)
            travel = player(probe).position.x - x1

            IO.puts(
              "[dolphin] shorten_frame=#{sf}: shortened_action=#{shortened?} travel=#{r(travel)}"
            )

            if travel < full_travel - 10.0,
              do: {:halt, {probe, {sf, travel}}},
              else: {:cont, {probe, nil}}
          end)

        IO.puts("[dolphin] illusion shorten: #{inspect(result)}")
        assert full_travel > 30.0
        assert result != nil
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "ledge-cancelled Illusion: the end slides off the BF platform edge", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_133, :falco, :battlefield)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # Calibrate the shortened phantasm's travel on the ground.
        probe = center_at(probe, -30.0)
        x0 = player(probe).position.x

        {probe, _} =
          run_tech(
            probe,
            Tech.new(:illusion, :falco, direction: :right, shorten_frame: 14),
            120,
            fn a, _ -> a end,
            nil
          )

        probe = settle(probe)
        travel = player(probe).position.x - x0
        IO.puts("\n[dolphin] shortened phantasm travel=#{r(travel)}")

        # Sweep the start offset so the phantasm's END overlaps the
        # platform's inner edge; the endlag slides off — instant
        # double jump out of the slip is the cancel discriminator.
        {probe, result} =
          Enum.reduce_while(
            [travel, travel - 2.0, travel + 2.0, travel - 4.0, travel + 4.0, travel - 6.0],
            {probe, nil},
            fn off, {probe, _} ->
              probe = mount_left_platform(probe)
              probe = platform_position(probe, @bf_left_inner_edge - off)

              {probe, _} =
                run_tech(
                  probe,
                  Tech.new(:illusion, :falco, direction: :right, shorten_frame: 14),
                  120,
                  fn a, _ -> a end,
                  nil
                )

              {probe, slipped?, dj?} = watch_slip(probe)

              IO.puts(
                "[dolphin] off=#{r(off)}: rest_x=#{r(player(probe).position.x)} " <>
                  "slipped=#{slipped?} dj_out=#{dj?}"
              )

              probe = recover(probe)

              if slipped? and dj?,
                do: {:halt, {probe, {off, true}}},
                else: {:cont, {probe, nil}}
            end
          )

        IO.puts("\n[dolphin] illusion edge cancel: #{inspect(result)}")
        assert result != nil
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "haxdash: ledge release -> instant DJ regrab, intangibility refreshed", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_135, :fox, :final_destination)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        {probe, result} =
          Enum.reduce_while([2, 3, 1, 4], {probe, nil}, fn delay, {probe, _} ->
            probe = recover(probe)
            {probe, hung?} = grab_right_ledge(probe, :fox, @fd_lip)

            # Let the original intangibility RUN OUT so the refresh is
            # provable.
            probe = Probe.idle!(probe, 80)
            pre = player(probe)

            {probe, frames} =
              if hung? do
                run_tech(
                  probe,
                  Tech.new(:haxdash, :fox, dj_delay: delay),
                  90,
                  fn n, _ -> n + 1 end,
                  0
                )
              else
                {probe, nil}
              end

            p = player(probe)
            regrabbed? = p.action in [0xFC, 0xFD]

            IO.puts(
              "[dolphin] dj_delay=#{delay}: hung=#{hung?} pre_invuln=#{pre.invulnerable} " <>
                "regrab=#{regrabbed?} frames=#{inspect(frames)} invuln=#{p.invulnerable}"
            )

            if regrabbed? and p.invulnerable and not pre.invulnerable,
              do: {:halt, {probe, {delay, frames}}},
              else: {:cont, {probe, nil}}
          end)

        IO.puts("\n[dolphin] haxdash: #{inspect(result)}")
        assert result != nil
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Falco ledgehop double laser", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_139, :falco, :final_destination)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        {probe, result} =
          Enum.reduce_while([10, 8, 12, 14], {probe, nil}, fn fd, {probe, _} ->
            probe = recover(probe)
            {probe, hung?} = grab_right_ledge(probe, :falco, @fd_lip)

            {probe, spawns} =
              if hung? do
                count_spawns_through(
                  probe,
                  Tech.new(:ledgehop_laser, :falco, direction: :right, fire_delay: fd),
                  150
                )
              else
                {probe, 0}
              end

            p = player(probe)
            landed_on? = p.on_ground and abs(p.position.x) < @fd_lip

            IO.puts(
              "[dolphin] fire_delay=#{fd}: hung=#{hung?} lasers=#{spawns} " <>
                "landed_on_stage=#{landed_on?}"
            )

            if spawns >= 2 and landed_on?,
              do: {:halt, {probe, {fd, spawns}}},
              else: {:cont, {probe, nil}}
          end)

        IO.puts("\n[dolphin] ledgehop double laser: #{inspect(result)}")
        assert result != nil
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "pivot grab: standing Catch facing the new way", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_141, :marth, :final_destination)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)
        probe = center_at(probe, -20.0)
        f0 = player(probe).facing
        dir = if f0, do: :right, else: :left

        {probe, {grabbed?, flipped?}} =
          run_tech(
            probe,
            Tech.new(:pivot_grab, :marth, direction: dir),
            60,
            fn {g, fl}, p ->
              hit = p.action == 0xD4
              {g or hit, fl or (hit and p.facing != f0)}
            end,
            {false, false}
          )

        IO.puts("\n[dolphin] pivot grab: catch=#{grabbed?} facing_flipped=#{flipped?}")
        assert grabbed?
        assert flipped?
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "boost grab: the dash attack's slide carried into the grab", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_143, :fox, :final_destination)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # Control: the JC grab's displacement from the same dash-in.
        probe = center_at(probe, -30.0)
        x0 = player(probe).position.x

        {probe, jc?} =
          run_tech(
            probe,
            Tech.new(:jc_grab, :fox),
            60,
            fn g, p -> g or p.action in 0xD4..0xD8 end,
            false
          )

        probe = wait_grab_over(probe)
        jc_slide = player(probe).position.x - x0
        probe = settle(probe)

        probe = center_at(probe, -30.0)
        x1 = player(probe).position.x

        {probe, boosted?} =
          run_tech(
            probe,
            Tech.new(:boost_grab, :fox, direction: :right),
            60,
            fn g, p -> g or p.action in 0xD4..0xD8 end,
            false
          )

        probe = wait_grab_over(probe)
        boost_slide = player(probe).position.x - x1

        IO.puts(
          "\n[dolphin] boost grab: jc_grab=#{jc?} slide=#{r(jc_slide)} vs " <>
            "boost=#{boosted?} slide=#{r(boost_slide)}"
        )

        assert jc?
        assert boosted?
        assert boost_slide > jc_slide + 3.0
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Yoshi double-jump armor: hit mid-DJ, damaged but never launched", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_145, :yoshi, :final_destination)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle_ports(probe, [1, 2])

        # Control: yoshi hit while FALLING (no armor) — launched.
        {probe, control} = armor_round(probe, false)
        IO.puts("\n[dolphin] control (falling, no armor): #{inspect(control)}")

        # Armor arm: the up-smash lands during the double jump.
        {probe, result} =
          Enum.reduce_while([0, 2, 4, 6, 8], {probe, nil}, fn k, {probe, _} ->
            {probe, res} = armor_round(probe, true, k)
            IO.puts("[dolphin] dj at usmash+#{k}: #{inspect(res)}")

            if res.hit? and res.armored?,
              do: {:halt, {probe, {k, res}}},
              else: {:cont, {probe, nil}}
          end)

        IO.puts("[dolphin] yoshi DJ armor: #{inspect(result)}")
        assert control.hit?
        refute control.armored?
        assert result != nil
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  ## yoshi armor ---------------------------------------------------------

  # One round: yoshi full-hops point-blank over falco's up-smash. In
  # the armor arm he DOUBLE JUMPS `k` frames after the up-smash starts
  # so the hit lands during the DJ (armored: damage but no launch);
  # the control eats it falling.
  defp armor_round(probe, dj?, k \\ 0) do
    probe = settle_ports(probe, [1, 2])
    probe = pair_up(probe)
    pct0 = player(probe).percent

    # Yoshi hops; falco up-smashes on a fixed frame. Armor = took the
    # damage but NEVER entered a damage/tumble ACTION (a launch-height
    # metric confounds with the DJ's own rise).
    res0 = %{hit?: false, damage_action?: false}

    {probe, res} =
      Enum.reduce_while(1..150, {probe, res0}, fn i, {probe, res} ->
        armor_inputs(probe, i, dj?, k)
        probe = Probe.step!(probe)
        yoshi = player(probe)

        res = %{
          hit?: res.hit? or yoshi.hitlag_left > 0,
          damage_action?:
            res.damage_action? or yoshi.action in 0x4B..0x5D or
              yoshi.action == 0x26
        }

        done? = res.hit? and yoshi.on_ground and yoshi.hitlag_left == 0 and i > 40
        if done?, do: {:halt, {probe, res}}, else: {:cont, {probe, res}}
      end)

    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])
    dmg = player(probe).percent - pct0
    probe = recover(probe)

    {probe,
     %{
       hit?: res.hit? and dmg > 0.0,
       armored?: res.hit? and dmg > 0.0 and not res.damage_action?,
       dmg: Float.round(dmg * 1.0, 1)
     }}
  end

  # The armor round's fixed input script: yoshi hops (1-4), falco
  # up-smashes (8), and the armor arm double-jumps at 8+k.
  defp armor_inputs(probe, i, dj?, k) do
    cond do
      i == 1 -> Melee.Controller.press_button(probe.controllers[1], :y)
      i == 4 -> Melee.Controller.release_button(probe.controllers[1], :y)
      i == 8 -> Melee.Controller.tilt_analog(probe.controllers[2], :c, 0.5, 1.0)
      i == 9 -> Melee.Controller.tilt_analog(probe.controllers[2], :c, 0.5, 0.5)
      dj? and i == 8 + k -> Melee.Controller.press_button(probe.controllers[1], :x)
      dj? and i == 10 + k -> Melee.Controller.release_button(probe.controllers[1], :x)
      true -> :ok
    end
  end

  # Yoshi near center; falco walked point-blank.
  defp pair_up(probe) do
    probe = center_at(probe, 0.0)
    probe = settle_ports(probe, [1, 2])
    me_x = player(probe).position.x
    falco = Probe.gamestate(probe).players[2]
    tilt = if falco.position.x > me_x + 6.0, do: 0.28, else: 0.72
    probe = walk_port(probe, 2, tilt, fn p -> abs(p.position.x - me_x) < 6.5 end)
    settle_ports(probe, [1, 2])
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

  defp r(v), do: Float.round(v * 1.0, 2)

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

  # Step the routine, counting projectile SPAWNS along the way.
  defp count_spawns_through(probe, tech, budget) do
    Enum.reduce_while(1..budget, {probe, tech, 0, 0}, fn _i, {probe, tech, spawns, prev} ->
      pl = player(probe)
      {status, tech} = Tech.step(tech, pl, probe.controllers[1])
      probe = Probe.step!(probe)
      n = length(Probe.gamestate(probe).projectiles)
      spawns = if n > prev, do: spawns + (n - prev), else: spawns

      if status == :done,
        do: {:halt, {probe, tech, spawns, n}},
        else: {:cont, {probe, tech, spawns, n}}
    end)
    |> then(fn {probe, _tech, spawns, _} -> {probe, spawns} end)
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

  # States that idle FOREVER on a released stick get a nudge.
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
        pl = Probe.gamestate(p).players[port]
        x = if pl != nil and pl.action in [0xF5, 0xF6], do: round(tilt_x) * 1.0, else: tilt_x
        Melee.Controller.tilt_analog(p.controllers[port], :main, x, 0.5)
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

        cond do
          pl != nil and pl.action == 0xFD ->
            Melee.Controller.press_button(p.controllers[1], :y)

          pl != nil and pl.action in [0xF5, 0xF6] ->
            x = if pl.facing, do: 0.28, else: 0.72
            Melee.Controller.tilt_analog(p.controllers[1], :main, x, 0.5)

          pl != nil and not pl.on_ground and pl.action in 0x1D..0x25 ->
            Melee.Controller.release_button(p.controllers[1], :y)
            x = if pl.position.x > 0, do: 0.2, else: 0.8
            Melee.Controller.tilt_analog(p.controllers[1], :main, x, 0.5)

          true ->
            Melee.Controller.release_all(p.controllers[1])
        end

        p
      end,
      timeout_frames: 1_800
    )
  end

  # After a grab connects, wait for the hold to resolve (the victim
  # escapes or is dropped) so the slide measurement is stable.
  defp wait_grab_over(probe) do
    Enum.reduce_while(1..120, probe, fn _i, probe ->
      probe = Probe.step!(probe)
      p = player(probe)

      if p.action in 0xD4..0xD9,
        do: {:cont, probe},
        else: {:halt, probe}
    end)
  end

  ## BF platform (illusion edge cancel) ---------------------------------

  defp mount_left_platform(probe) do
    probe = recover(probe)

    if player(probe).position.y > 20.0 do
      probe
    else
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
          timeout_frames: 180
        )

      settle(probe)
    end
  end

  defp platform_position(probe, x) do
    me = player(probe)

    probe =
      cond do
        me.position.x > x + 1.5 -> walk_until(probe, 0.32, fn p -> p.position.x < x + 1.0 end)
        me.position.x < x - 1.5 -> walk_until(probe, 0.68, fn p -> p.position.x > x - 1.0 end)
        true -> probe
      end

    settle(probe)
  end

  # After a touchdown near the platform edge: did it slide off, and is
  # the character INSTANTLY actionable (a double jump out of the slip)?
  defp watch_slip(probe) do
    Enum.reduce_while(1..25, {probe, false, false, false}, fn _i, {probe, slipped, pressed, _} ->
      p = player(probe)

      cond do
        not p.on_ground and p.position.y < 26.2 and not pressed ->
          Melee.Controller.press_button(probe.controllers[1], :y)
          probe = Probe.step!(probe)
          {:cont, {probe, true, true, false}}

        pressed ->
          Melee.Controller.release_button(probe.controllers[1], :y)
          probe = Probe.step!(probe)
          p2 = player(probe)

          cond do
            p2.action in [0x1B, 0x1C] -> {:halt, {probe, slipped, true, true}}
            p2.on_ground -> {:halt, {probe, slipped, true, false}}
            true -> {:cont, {probe, slipped, true, false}}
          end

        true ->
          probe = Probe.step!(probe)
          {:cont, {probe, slipped, pressed, false}}
      end
    end)
    |> then(fn {probe, slipped, _pressed, dj} ->
      Melee.Controller.release_all(probe.controllers[1])
      {probe, slipped, dj}
    end)
  end

  ## ledge grab (character-generic) -------------------------------------

  # Walk to the right edge facing LEFT (via pivot), then backward
  # wavedash off — the freefall grabs the ledge.
  defp grab_right_ledge(probe, character, lip) do
    probe = walk_until(probe, 0.28, fn p -> p.position.x < lip - 25.0 end)
    probe = settle(probe)
    probe = walk_until(probe, 0.72, fn p -> p.position.x > lip - 17.0 end)
    probe = settle(probe)

    {probe, _} =
      run_tech(
        probe,
        Tech.new(:pivot, character, direction: :right, dash_frames: 4),
        60,
        fn a, _ -> a end,
        nil
      )

    probe = settle(probe)

    {probe, hung?} =
      run_tech(
        probe,
        Tech.new(:wavedash, character, direction: :right),
        120,
        fn a, p ->
          a or p.action == 0xFD
        end,
        false
      )

    if hung? do
      {probe, true}
    else
      Enum.reduce_while(1..120, {probe, false}, fn _i, {probe, _} ->
        Melee.Controller.release_all(probe.controllers[1])
        probe = Probe.step!(probe)
        p = Probe.gamestate(probe).players[1]

        if p != nil and p.action == 0xFD,
          do: {:halt, {probe, true}},
          else: {:cont, {probe, false}}
      end)
    end
  end
end
