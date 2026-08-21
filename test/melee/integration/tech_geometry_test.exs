defmodule Melee.Integration.TechGeometryTest do
  use ExUnit.Case

  @moduledoc """
  The geometry round: techniques that live on edges, lips, and walls.
  Four live proofs:

    * edge cancel — a WAVEDASH's special landing slides off the BF
      platform edge into instant actionability (double jump out of
      the slip). An AERIAL landing's slide CLAMPS at the lip under a
      NEUTRAL stick (rest_x exactly -20.0 even at dash momentum) but
      carries OFF with the direction HELD through the landing lag —
      the pro-play drop-off input;
    * no-impact land — on FoD, whose side platforms sweep their
      height continuously, a repeated short hop eventually crosses a
      lip inside the no-impact window: NO Landing action at all and
      0-frame actionability (a fixed platform is unreachable — the DJ
      press grid is ~1.3 units coarse, measured on BF);
    * walljump — Yoshi's Story's right flank is real wall at
      x 52.67..53.73 all the way down (`Melee.Stages.wall_segments`,
      extracted from the stage .dat): dash off the lip, hug full-in,
      detect contact as "x stopped while falling", flick away —
      Melee's plain walljump plays action 0xCB (the WallTechJump id);
    * walltech — falco dair-spikes the YS ledge-hanger at tumble
      percent; :walltech parks both sticks INTO the wall (the ASDI
      shift manufactures the impact) — 0xCA right off the hang.

  FD and PS have almost no reachable wall (FD's is 10.5 units tall
  below the lip, PS's 4 — a hanging body sits BELOW both), which is
  why every earlier attempt there whiffed.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_geometry
  """

  alias Melee.{Enums, Probe, Tech}

  @moduletag :dolphin
  @moduletag :dolphin_geometry
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_geometry_it")

  @landing 0x2A
  @aerial_jumps [0x1B, 0x1C]
  @wall_techs [0xCA, 0xCB]
  @ys_lip 56.0
  # YS's right flank is wall at x 52.67..53.73 (Melee.Stages).
  @ys_wall_x 53.7
  # BF side platform: y 27.2, left one spans x -57.6..-20.
  @bf_plat_y 27.2
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

  test "edge-cancelled aerial: drifted SHFFL slides off the BF platform edge", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_121, :fox, :battlefield)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)
        probe = mount_left_platform(probe)

        # Control: the same no-L-cancel uair landed mid-platform — the
        # lag an edge cancel must beat.
        probe = platform_position(probe, -40.0)

        {probe, _} =
          run_tech(
            probe,
            Tech.new(:shffl, :fox, aerial: :uair, l_cancel: false),
            120,
            fn a, _ -> a end,
            nil
          )

        {probe, control_lag} = frames_to_dash(probe)

        IO.puts(
          "\n[dolphin] control uair landing (mid-platform): actionable_in=#{inspect(control_lag)}"
        )

        # FINDING (measured): AERIAL landing slides CLAMP at platform
        # edges on this engine — even a dash-momentum touchdown at
        # -21.9 slid to exactly -20.0 and stopped. Pin that as the
        # control fact: a dash-jumped uair landed by the lip never
        # slides off.
        probe = mount_left_platform(probe)
        probe = platform_position(probe, @bf_left_inner_edge - 34.0)

        probe =
          Enum.reduce(1..4, probe, fn _i, probe ->
            Melee.Controller.tilt_analog(probe.controllers[1], :main, 1.0, 0.5)
            Probe.step!(probe)
          end)

        {probe, _} =
          run_tech(
            probe,
            Tech.new(:shffl, :fox, aerial: :uair, l_cancel: false, drift: :right),
            120,
            fn a, _ -> a end,
            nil
          )

        {probe, clamp_slipped?, _} = watch_slip(probe)
        clamp_rest = player(probe).position.x

        IO.puts(
          "[dolphin] aerial-landing clamp: rest_x=#{r(clamp_rest)} slipped=#{clamp_slipped?}"
        )

        probe = recover(probe)

        # The pro-play variant: HOLD the direction through the landing
        # lag — does the held stick carry the landing off the lip
        # where the neutral-stick slide clamped?
        probe = mount_left_platform(probe)
        probe = platform_position(probe, @bf_left_inner_edge - 34.0)

        probe =
          Enum.reduce(1..4, probe, fn _i, probe ->
            Melee.Controller.tilt_analog(probe.controllers[1], :main, 1.0, 0.5)
            Probe.step!(probe)
          end)

        {probe, _} =
          run_tech(
            probe,
            Tech.new(:shffl, :fox, aerial: :uair, l_cancel: false, drift: :right),
            120,
            fn a, _ -> a end,
            nil
          )

        {probe, held_slipped?, held_dj?} = watch_slip_holding(probe)

        IO.puts(
          "[dolphin] held-direction landing: rest_x=#{r(player(probe).position.x)} " <>
            "slipped=#{held_slipped?} dj_out=#{held_dj?}"
        )

        probe = recover(probe)

        # The cancel that DOES slide: a SPECIAL landing (wavedash)
        # carries off the edge. Sweep the start offset; prove the
        # cancel with an INSTANT double jump out of the slip (the
        # teleport edge-cancel discriminator).
        {probe, result} =
          Enum.reduce_while(
            [12.0, 15.0, 9.0, 18.0, 6.0, 21.0],
            {probe, nil},
            fn off, {probe, _} ->
              probe = mount_left_platform(probe)
              probe = platform_position(probe, @bf_left_inner_edge - off)

              {probe, _} =
                run_tech(
                  probe,
                  Tech.new(:wavedash, :fox, direction: :right),
                  120,
                  fn a, _ -> a end,
                  nil
                )

              {probe, slipped?, dj?} = watch_slip(probe)

              IO.puts(
                "[dolphin] wavedash off=#{off}: rest_x=#{r(player(probe).position.x)} " <>
                  "slipped=#{slipped?} dj_out=#{dj?}"
              )

              probe = recover(probe)

              if slipped? and dj?,
                do: {:halt, {probe, {off, true}}},
                else: {:cont, {probe, nil}}
            end
          )

        IO.puts("[dolphin] edge cancel (wavedash slide-off): #{inspect(result)}")
        assert control_lag != nil and control_lag >= 3
        # The clamp is NEUTRAL-STICK only: released, the landing stops
        # AT the lip; the same landing with the direction HELD carries
        # off into an instant double jump — the pro-play drop-off.
        assert not clamp_slipped?
        assert_in_delta clamp_rest, @bf_left_inner_edge, 0.1
        assert held_slipped?
        assert held_dj?
        assert result != nil
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "no-impact land: FoD's sweeping platform meets the hop apex — zero landing frames", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_123, :marth, :fountain_of_dreams)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # Control: a plain short hop onto the GROUND — the normal
        # Landing (0x2A) with its lag.
        probe = center_at(probe, 0.0)
        {probe, control_action} = hop_and_land(probe)
        {probe, control_lag} = frames_to_dash(probe)

        IO.puts(
          "\n[dolphin] control SH landing: first_action=#{inspect(control_action, base: :hex)} lag=#{inspect(control_lag)}"
        )

        # A fixed-apex jump can only reach a frame-quantized grid of
        # apex-vs-lip offsets against a FIXED platform (measured on BF:
        # never inside the window). FoD's side platforms sweep their
        # height continuously, so the same short hop repeated under one
        # eventually crosses the lip inside the no-impact window.
        {probe, nil_result} =
          Enum.reduce_while(1..150, {probe, nil}, fn rep, {probe, _} ->
            probe = park_under_platform(probe)
            {probe, first_action} = hop_and_land(probe)
            p = player(probe)
            on_plat? = p.on_ground and p.position.y > 2.0
            {probe, lag} = if on_plat?, do: frames_to_dash(probe), else: {probe, nil}

            nil? =
              on_plat? and first_action != nil and first_action != @landing and lag != nil and
                lag <= 1

            if on_plat? do
              IO.puts(
                "[dolphin] rep #{rep}: platform landing y=#{r(p.position.y)} " <>
                  "first_action=#{inspect(first_action, base: :hex)} lag=#{inspect(lag)}"
              )
            end

            if nil?,
              do: {:halt, {probe, {rep, first_action, lag}}},
              else: {:cont, {probe, nil}}
          end)

        IO.puts("[dolphin] no-impact land: #{inspect(nil_result)}")
        assert control_action == @landing
        assert control_lag != nil and control_lag >= 2
        assert nil_result != nil
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "walljump: slide off YS's lip, hug in to the real wall, flick away", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_125, :fox, :yoshis_story)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        walls = Melee.Stages.wall_segments(:yoshis_story, :right)
        IO.puts("\n[dolphin] YS right wall: #{inspect(walls, limit: 4)} ...")

        # The wavedash slide-off drops fox at the lip facing RIGHT (no
        # ledge regrab — grabs need the facing), and YS's right flank
        # is real wall from -10.5 all the way down (x 52.67..53.73 —
        # Melee.Stages.wall_segments). Hug full-in, detect contact as
        # "x stopped while falling", flick away.
        {probe, result} =
          Enum.reduce_while([1, 2, 3], {probe, nil}, fn attempt, {probe, _} ->
            probe = recover(probe)
            probe = center_at(probe, @ys_lip - 15.0)

            # Dash off the lip facing RIGHT (a walk teeters; a
            # leftward-facing exit regrabs the ledge on the way down).
            {probe, off?} =
              Enum.reduce_while(1..90, {probe, false}, fn _i, {probe, _} ->
                Melee.Controller.tilt_analog(probe.controllers[1], :main, 1.0, 0.5)
                probe = Probe.step!(probe)
                p = player(probe)

                if p.on_ground,
                  do: {:cont, {probe, false}},
                  else: {:halt, {probe, true}}
              end)

            Melee.Controller.release_all(probe.controllers[1])

            {probe, trace} =
              if off? do
                run_tech(
                  probe,
                  Tech.new(:walljump, :fox, direction: :right, edge_x: @ys_lip, dive_y: -70.0),
                  300,
                  fn tr, p ->
                    e =
                      {p.action, Float.round(p.position.x, 1), Float.round(p.position.y, 1),
                       Float.round(p.speed_y_self, 2), p.jumps_left}

                    if tr == [] or elem(hd(tr), 0) != p.action, do: [e | tr], else: tr
                  end,
                  []
                )
              else
                {probe, []}
              end

            trace = Enum.reverse(trace)
            slipped? = off?
            off = attempt

            # Melee's plain walljump plays action 0xCB — the same id
            # as WallTechJump (discovered here: the flick out of the
            # wall-ride entered 0xCB with no damage state anywhere).
            jumped = Enum.find(trace, fn {a, _x, _y, _vy, _j} -> a == 0xCB end)

            IO.puts(
              "\n[dolphin] off=#{off}: slipped=#{slipped?} walljump=#{inspect(jumped, base: :hex)} " <>
                "trace=#{inspect(trace, base: :hex, limit: 14)}"
            )

            probe = recover(probe)

            if jumped != nil,
              do: {:halt, {probe, {off, jumped}}},
              else: {:cont, {probe, nil}}
          end)

        assert result != nil
        {_off, {_action, _x, _y, _vy, jumps_left}} = result
        # The rise spent no aerial jump: the slide-off leaves exactly
        # the double jump, and it must still be in pocket.
        assert jumps_left >= 1
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "walltech: falco dair-spikes the YS hanger onto the real wall", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_127, :fox, :yoshis_story)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle_ports(probe, [1, 2])

        {probe, teched?, _} =
          Enum.reduce_while(
            [54.0, 55.0, 53.0, 52.0, 51.0],
            {probe, false, nil},
            fn falco_x, {probe, _, _} ->
              {probe, seen, trace} = walltech_round(probe, falco_x)
              teched? = Enum.any?(@wall_techs, &MapSet.member?(seen, &1))

              IO.puts(
                "\n[dolphin] walltech (falco at #{falco_x}): teched=#{teched?} " <>
                  "actions=#{inspect(Enum.sort(MapSet.to_list(seen)), base: :hex)} " <>
                  "trace=#{inspect(trace, base: :hex, limit: 20)}"
              )

              probe = recover(probe)

              if teched?,
                do: {:halt, {probe, true, trace}},
                else: {:cont, {probe, false, trace}}
            end
          )

        assert teched?
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
        Enum.each(ports, &release_or_unteeter(p, &1))
        p
      end,
      timeout_frames: 900
    )
  end

  # A lip-teeter (0xF5/6) idles forever: step back from the edge
  # (away from the facing) instead of waiting.
  defp release_or_unteeter(probe, port) do
    pl = Probe.gamestate(probe).players[port]

    if pl != nil and pl.action in [0xF5, 0xF6] do
      x = if pl.facing, do: 0.28, else: 0.72
      Melee.Controller.tilt_analog(probe.controllers[port], :main, x, 0.5)
    else
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

        # A WALK never crosses a lip — it teeters and stalls (0xF5/6).
        # Smash the stick to dash off and keep going.
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

  # Frames from a touchdown until a held dash input produces grounded
  # movement — the real landing LAG (see the research suite's
  # actionability-not-animation lesson).
  defp frames_to_dash(probe) do
    Enum.reduce_while(1..40, {probe, 0, []}, fn _i, {probe, n, tr} ->
      Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.0, 0.5)
      probe = Probe.step!(probe)
      p = player(probe)

      tr =
        if tr == [] or elem(hd(tr), 0) != p.action,
          do: [{p.action, trunc(p.action_frame)} | tr],
          else: tr

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

  # After an attempt fox may be offstage or falling: drift toward
  # center until standing again (respawn or landing both work).
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
          # Hanging: climb up (a hang with a released controller lasts
          # forever).
          pl != nil and pl.action == 0xFD ->
            Melee.Controller.press_button(p.controllers[1], :y)

          # Teetering idles forever too: step back from the edge.
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

  ## edge cancel --------------------------------------------------------

  # Stand under the LEFT side platform and full hop onto it (the
  # shield-drop route); if already up there, done.
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

  # Walk along the platform (gently — the inner edge is close) to x.
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

  # watch_slip, but with the toward-the-edge direction HELD through
  # the landing lag (the pro-play input for dropping off).
  defp watch_slip_holding(probe) do
    Enum.reduce_while(1..25, {probe, false, false, false}, fn _i, {probe, slipped, pressed, _} ->
      p = player(probe)

      cond do
        not p.on_ground and p.position.y < @bf_plat_y - 1.0 and not pressed ->
          Melee.Controller.press_button(probe.controllers[1], :y)
          probe = Probe.step!(probe)
          {:cont, {probe, true, true, false}}

        pressed ->
          Melee.Controller.release_button(probe.controllers[1], :y)
          probe = Probe.step!(probe)
          p2 = player(probe)

          cond do
            p2.action in @aerial_jumps -> {:halt, {probe, slipped, true, true}}
            p2.on_ground -> {:halt, {probe, slipped, true, false}}
            true -> {:cont, {probe, slipped, true, false}}
          end

        true ->
          Melee.Controller.tilt_analog(probe.controllers[1], :main, 1.0, 0.5)
          probe = Probe.step!(probe)
          {:cont, {probe, slipped, pressed, false}}
      end
    end)
    |> then(fn {probe, slipped, _pressed, dj} ->
      Melee.Controller.release_all(probe.controllers[1])
      {probe, slipped, dj}
    end)
  end

  # After the aerial's touchdown: did the landing slide off the edge,
  # and is fox INSTANTLY actionable (a double jump out of the slip)?
  defp watch_slip(probe) do
    Enum.reduce_while(1..25, {probe, false, false, false}, fn _i, {probe, slipped, pressed, _} ->
      p = player(probe)

      cond do
        # Off the platform mid-air: press jump the moment we notice.
        not p.on_ground and p.position.y < @bf_plat_y - 1.0 and not pressed ->
          Melee.Controller.press_button(probe.controllers[1], :y)
          probe = Probe.step!(probe)
          {:cont, {probe, true, true, false}}

        pressed ->
          Melee.Controller.release_button(probe.controllers[1], :y)
          probe = Probe.step!(probe)
          p2 = player(probe)

          cond do
            p2.action in @aerial_jumps -> {:halt, {probe, slipped, true, true}}
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

  ## no-impact land -----------------------------------------------------

  # One short hop (via the routine, which ends at touchdown); returns
  # the FIRST grounded action — a NIL never shows Landing (0x2A).
  defp hop_and_land(probe) do
    run_tech(
      probe,
      Tech.new(:no_impact_land, :marth, hop: :short, trigger_y: 999.0),
      200,
      fn {air, fa}, p ->
        air = air or not p.on_ground
        fa = if fa == nil and air and p.on_ground, do: p.action, else: fa
        {air, fa}
      end,
      {false, nil}
    )
    |> then(fn {probe, {_air, fa}} -> {probe, fa} end)
  end

  # Off any platform, parked on the ground under the left one.
  defp park_under_platform(probe) do
    p = player(probe)

    probe =
      if p.on_ground and p.position.y > 2.0 do
        probe = walk_until(probe, 0.72, fn pl -> pl.position.y < 1.0 end)
        recover(probe)
      else
        probe
      end

    center_at(probe, -35.0)
  end

  ## walljump / walltech (Yoshi's Story) --------------------------------

  # Step a routine that should stop being stepped once done.
  defp step_until_done(nil, _player, _controller), do: nil

  defp step_until_done(tech, player, controller) do
    case Tech.step(tech, player, controller) do
      {:done, _} -> nil
      {:cont, t} -> t
    end
  end

  # Falco up-smashes fox point-blank mid-stage until he carries
  # `target` percent (vertical launches; fox lands back).
  defp build_percent(probe, target) do
    fox = player(probe)

    if fox.percent >= target do
      {probe, fox.percent}
    else
      probe = settle_ports(probe, [1, 2])
      probe = center_at(probe, 0.0)
      target_x = player(probe).position.x - 6.0
      falco = Probe.gamestate(probe).players[2]
      tilt = if falco.position.x > target_x, do: 0.28, else: 0.72
      probe = walk_port(probe, 2, tilt, fn p -> abs(p.position.x - target_x) < 2.0 end)
      probe = settle_ports(probe, [1, 2])

      Melee.Controller.tilt_analog(probe.controllers[2], :c, 0.5, 1.0)
      probe = Probe.step!(probe)
      Melee.Controller.tilt_analog(probe.controllers[2], :c, 0.5, 0.5)
      probe = Enum.reduce(1..90, probe, fn _i, probe -> Probe.step!(probe) end)
      probe = recover(probe)
      build_percent(probe, target)
    end
  end

  # Walk to the right edge facing LEFT (via pivot), then backward
  # wavedash off — the freefall grabs the ledge.
  defp grab_right_ledge(probe, lip) do
    probe = walk_until(probe, 0.28, fn p -> p.position.x < lip - 25.0 end)
    probe = settle(probe)
    probe = walk_until(probe, 0.72, fn p -> p.position.x > lip - 17.0 end)
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

    {probe, hung?} =
      run_tech(
        probe,
        Tech.new(:wavedash, :fox, direction: :right),
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

  # One round: fox hangs on YS's right ledge, falco short-hop DAIRS
  # the hanger; the armed :walltech parks both sticks INTO the wall
  # (the ASDI shift plus tumble drift press the fall onto the real
  # x 52.67..53.73 wall) and techs on contact.
  defp walltech_round(probe, falco_x) do
    probe = settle_ports(probe, [1, 2])

    # A 0% spike gives hitstun -> plain Fall (no tumble, nothing to
    # tech — measured: fox rode the wall pinned at x 55.8 all the way
    # to the blast zone); build tumble percent first, and rebuild
    # after deaths.
    {probe, _} = build_percent(probe, 45.0)

    # Falco parks near the edge first so his walk can't bump fox off.
    probe = walk_port(probe, 2, 0.72, fn p -> p.position.x > @ys_lip - 14.0 end)
    probe = settle_ports(probe, [1, 2])

    {probe, hung?} = grab_right_ledge(probe, @ys_lip)

    if hung? do
      # Wait out the ledge intangibility, then walk falco to range.
      probe = Probe.idle!(probe, 80)
      falco = Probe.gamestate(probe).players[2]
      tilt = if falco.position.x > falco_x, do: 0.28, else: 0.72
      probe = walk_port(probe, 2, tilt, fn p -> abs(p.position.x - falco_x) < 1.2 end)
      Melee.Controller.release_all(probe.controllers[2])
      probe = Probe.step!(probe)

      dair = Tech.new(:shffl, :falco, aerial: :dair, l_cancel: false, drift: :right)
      wt = Tech.new(:walltech, :fox, wall_x: @ys_wall_x, margin: 7.0)

      {probe, _machines, seen, trace} =
        Enum.reduce(1..200, {probe, {dair, wt}, MapSet.new(), []}, fn _i,
                                                                      {probe, {dair, wt}, seen,
                                                                       tr} ->
          gs = Probe.gamestate(probe)
          fox = gs.players[1]
          dair = step_until_done(dair, gs.players[2], probe.controllers[2])
          {_status, wt} = Tech.step(wt, fox, probe.controllers[1])

          probe = Probe.step!(probe)
          p = player(probe)
          seen = MapSet.put(seen, p.action)

          e = {p.action, Float.round(p.position.x, 1), Float.round(p.position.y, 1)}
          tr = if tr == [] or elem(hd(tr), 0) != p.action, do: [e | tr], else: tr
          {probe, {dair, wt}, seen, tr}
        end)

      Melee.Controller.release_all(probe.controllers[1])
      Melee.Controller.release_all(probe.controllers[2])
      {probe, seen, Enum.reverse(trace)}
    else
      {probe, MapSet.new(), [:no_hang]}
    end
  end
end
