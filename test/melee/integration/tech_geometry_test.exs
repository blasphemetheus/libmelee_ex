defmodule Melee.Integration.TechGeometryTest do
  use ExUnit.Case

  @moduledoc """
  The geometry round: techniques that live on edges and lips. Two
  live proofs plus two measured engine facts:

    * edge cancel — a WAVEDASH's special landing slides off the BF
      platform edge into instant actionability (double jump out of
      the slip), while an AERIAL landing's slide CLAMPS at the lip
      even with dash momentum (rest_x exactly -20.0 — so "edge
      cancelled aerials" via landing slides don't exist on this
      engine; cancels belong to special landings and end animations);
    * no-impact land — on FoD, whose side platforms sweep their
      height continuously, a repeated short hop eventually crosses a
      lip inside the no-impact window: NO Landing action at all and
      0-frame actionability (a fixed platform is unreachable — the DJ
      press grid is ~1.3 units coarse, measured on BF).

  Walljump/walltech live proofs are NOT here: every entry mapped
  (ledge drops on FD/PS/YS, hop-outs, wavedash slide-offs) fell PAST
  the lips without ever registering wall contact — see melee-tech.md
  for the maps; cracking that needs a windowed session.

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
        # The clamp: the aerial landing stopped AT the lip, never off.
        assert not clamp_slipped?
        assert_in_delta clamp_rest, @bf_left_inner_edge, 0.1
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
end
