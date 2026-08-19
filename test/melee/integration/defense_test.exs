defmodule Melee.Integration.DefenseTest do
  use ExUnit.Case

  @moduledoc """
  Tier-4 hit-response routines proven against a scripted launcher: falco
  (port 2, also ours) up-smashes fox (port 1) point blank. The vertical
  launch makes the measurements percent-robust:

    * SDI — displacement DURING hitlag: a frozen control barely moves,
      the SDI run slides several units per input;
    * DI — horizontal drift of the post-hitlag knockback path: the
      control flies straight up, full-left DI tilts the trajectory;
    * ground tech — at tumble percents the fall back down arms `:tech`
      and a tech state must appear (the live proof the movement tier
      deferred).

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_defense
  """

  alias Melee.{Enums, Probe, Tech}

  @moduletag :dolphin
  @moduletag :dolphin_defense
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_defense_it")

  @tech_states [0xC7, 0xC8, 0xC9]

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

  test "SDI, DI, and a live ground tech under falco's up-smash", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx)

      try do
        probe = Probe.idle!(probe, 90)

        # --- Control: no inputs from fox. One run doubles as the
        # control for both measurements.
        {probe, control} = measured_launch(probe, nil, 20)
        assert control.hit?, "control up-smash whiffed"

        # --- SDI left: displacement during hitlag must beat control's.
        {probe, sdi} = measured_launch(probe, Tech.new(:sdi, :fox, direction: :left), 20)
        assert sdi.hit?, "sdi up-smash whiffed"

        IO.puts(
          "\n[dolphin] hitlag slide: control=#{r(control.hitlag_slide)} sdi=#{r(sdi.hitlag_slide)} (#{control.hitlag_frames}/#{sdi.hitlag_frames} hitlag frames)"
        )

        assert sdi.hitlag_slide > control.hitlag_slide + 3.0

        # --- DI left: horizontal drift of the knockback path.
        {probe, di} = measured_launch(probe, Tech.new(:di, :fox, stick: :left), 20)
        assert di.hit?, "di up-smash whiffed"

        IO.puts(
          "[dolphin] knockback dx over 20f: control=#{r(control.post_dx)} di=#{r(di.post_dx)}"
        )

        assert abs(di.post_dx) > abs(control.post_dx) + 3.0

        # --- Ground tech: build tumble percent, then launch with :tech
        # armed and require a tech state on the way down.
        {probe, percent} = build_percent(probe, 55.0)
        IO.puts("[dolphin] fox at #{r(percent)}% for the tech launch")

        {probe, teched?, seen} = tech_launch(probe)
        IO.puts("[dolphin] ground tech: teched=#{teched?} actions_seen=#{inspect(seen)}")
        assert teched?

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
        slippi_port: 52_071,
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

  defp r(v), do: Float.round(v * 1.0, 2)

  defp player(probe, port), do: Probe.gamestate(probe).players[port]

  # Neutral both controllers; wait until both are grounded and idle.
  defp settle_both(probe) do
    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])

    Probe.until!(
      probe,
      fn p ->
        p1 = player(p, 1)
        p2 = player(p, 2)

        p1 != nil and p2 != nil and p1.on_ground and p2.on_ground and
          p1.hitlag_left == 0 and p1.action < 0x40 and p2.action < 0x40
      end,
      fn p ->
        Melee.Controller.release_all(p.controllers[1])
        Melee.Controller.release_all(p.controllers[2])
        p
      end,
      timeout_frames: 900
    )
  end

  defp walk_port(probe, port, tilt_x, done?) do
    Probe.until!(
      probe,
      fn p ->
        pl = player(p, port)
        pl != nil and done?.(pl)
      end,
      fn p ->
        Melee.Controller.tilt_analog(p.controllers[port], :main, tilt_x, 0.5)
        p
      end,
      timeout_frames: 900
    )
  end

  # Fox near center, falco walked to point-blank range on fox's right.
  defp stage_setup(probe) do
    probe = settle_both(probe)

    # Nudge fox back toward center if earlier knockback pushed him out.
    fox = player(probe, 1)

    probe =
      cond do
        fox.position.x > 25.0 -> walk_port(probe, 1, 0.28, &(&1.position.x < 15.0))
        fox.position.x < -25.0 -> walk_port(probe, 1, 0.72, &(&1.position.x > -15.0))
        true -> probe
      end

    probe = settle_both(probe)
    fox_x = player(probe, 1).position.x

    # Falco approaches from whichever side he is on until point blank.
    falco = player(probe, 2)
    tilt = if falco.position.x > fox_x, do: 0.28, else: 0.72
    probe = walk_port(probe, 2, tilt, fn p -> abs(p.position.x - fox_x) < 7.0 end)
    settle_both(probe)
  end

  # Up-smash from falco; step `tech` (or nothing) on fox every frame.
  # Tracks fox's position through hitlag and `post_frames` beyond it.
  defp measured_launch(probe, tech, post_frames, attempts \\ 3) do
    probe = stage_setup(probe)

    Melee.Controller.tilt_analog(probe.controllers[2], :c, 0.5, 1.0)
    probe = Probe.step!(probe)
    Melee.Controller.tilt_analog(probe.controllers[2], :c, 0.5, 0.5)

    acc0 = {probe, tech, :waiting, [], []}

    {probe, _tech, phase, hitlag_path, post_path} =
      Enum.reduce_while(1..(60 + post_frames), acc0, fn i, {probe, tech, phase, hitlag, post} ->
        fox = player(probe, 1)

        tech =
          if tech do
            {_status, tech2} = Tech.step(tech, fox, probe.controllers[1])
            tech2
          end

        probe = Probe.step!(probe)
        fox = player(probe, 1)

        {phase, hitlag, post} =
          case {phase, fox.hitlag_left > 0} do
            {:waiting, true} -> {:hitlag, [fox.position | hitlag], post}
            {:waiting, false} -> {:waiting, hitlag, post}
            {:hitlag, true} -> {:hitlag, [fox.position | hitlag], post}
            {:hitlag, false} -> {:post, hitlag, [fox.position | post]}
            {:post, _} -> {:post, hitlag, [fox.position | post]}
          end

        acc = {probe, tech, phase, hitlag, post}

        cond do
          phase == :post and length(post) >= post_frames -> {:halt, acc}
          phase == :waiting and i > 50 -> {:halt, acc}
          true -> {:cont, acc}
        end
      end)

    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])

    if phase == :waiting do
      if attempts > 1 do
        measured_launch(probe, tech, post_frames, attempts - 1)
      else
        {probe, %{hit?: false, hitlag_slide: 0.0, hitlag_frames: 0, post_dx: 0.0}}
      end
    else
      hitlag_path = Enum.reverse(hitlag_path)
      post_path = Enum.reverse(post_path)

      slide =
        case {List.first(hitlag_path), List.last(hitlag_path)} do
          {nil, _} -> 0.0
          {a, b} -> :math.sqrt(:math.pow(b.x - a.x, 2) + :math.pow(b.y - a.y, 2))
        end

      dx =
        case {List.first(post_path), List.last(post_path)} do
          {nil, _} -> 0.0
          {a, b} -> b.x - a.x
        end

      {probe, %{hit?: true, hitlag_slide: slide, hitlag_frames: length(hitlag_path), post_dx: dx}}
    end
  end

  defp build_percent(probe, target) do
    fox = player(probe, 1)

    if fox.percent >= target do
      {probe, fox.percent}
    else
      {probe, _} = measured_launch(probe, nil, 5)
      probe = settle_both(probe)
      build_percent(probe, target)
    end
  end

  # Launch at tumble percent with :tech armed; watch the fall for a
  # tech state.
  defp tech_launch(probe) do
    probe = stage_setup(probe)
    tech = Tech.new(:tech, :fox, direction: :in_place)

    Melee.Controller.tilt_analog(probe.controllers[2], :c, 0.5, 1.0)
    probe = Probe.step!(probe)
    Melee.Controller.tilt_analog(probe.controllers[2], :c, 0.5, 0.5)

    {probe, _tech, seen} =
      Enum.reduce(1..180, {probe, tech, MapSet.new()}, fn _i, {probe, tech, seen} ->
        fox = player(probe, 1)
        {_status, tech} = Tech.step(tech, fox, probe.controllers[1])
        probe = Probe.step!(probe)
        fox = player(probe, 1)
        seen = if fox != nil, do: MapSet.put(seen, fox.action), else: seen
        {probe, tech, seen}
      end)

    Melee.Controller.release_all(probe.controllers[1])
    Melee.Controller.release_all(probe.controllers[2])
    teched? = Enum.any?(@tech_states, &MapSet.member?(seen, &1))
    interesting = seen |> Enum.filter(&(&1 >= 0xB0 and &1 <= 0xD0)) |> Enum.sort()
    {probe, teched?, interesting}
  end
end
