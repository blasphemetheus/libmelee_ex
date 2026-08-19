defmodule Melee.Integration.MewtwoTechTest do
  use ExUnit.Case

  @moduledoc """
  Mewtwo's kit, live: DJC nair (his double jump is a slow roll — the
  cancel must still keep the aerial low), shadow ball charge stored via
  shield-cancel, the fired projectile observed, and the teledgehog
  ending on the ledge.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_mewtwo
  """

  alias Melee.{Enums, Probe, Tech}

  @moduletag :dolphin
  @moduletag :dolphin_mewtwo
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_mewtwo_it")

  @neutral_b_charging 0x156
  @neutral_b_cancel 0x158
  @neutral_b_fire 0x159
  @edge_catch 0xFC
  @edge_hanging 0xFD

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

  test "DJC nair, shadow ball store + fire, teledgehog", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        # --- DJC nair: attack comes out, apex stays low.
        nair = Enums.Action.to_id(:nair)

        {probe, {attacked?, apex}} =
          run_tech(
            probe,
            Tech.new(:djc_aerial, :mewtwo, aerial: :nair),
            90,
            fn {a, apex}, p -> {a or p.action == nair, max(apex, p.position.y)} end,
            {false, 0.0}
          )

        IO.puts("\n[dolphin] mewtwo djc nair: attacked=#{attacked?} apex=#{Float.round(apex, 2)}")
        assert attacked?
        assert apex < 12.0

        # --- Shadow ball: charge, then shield-cancel to store it.
        # Fire recoil pushes mewtwo backward: work from center-right.
        probe = settle(probe)

        probe =
          if Probe.gamestate(probe).players[1].position.x < 0.0,
            do: walk_until(probe, 0.72, fn x -> x > 5.0 end),
            else: probe

        probe = settle(probe)

        {probe, {charged?, cancelled?}} =
          run_tech(
            probe,
            Tech.new(:shadow_ball_charge, :mewtwo, frames: 45),
            120,
            fn {c, s}, p ->
              {c or p.action == @neutral_b_charging, s or p.action == @neutral_b_cancel}
            end,
            {false, false}
          )

        IO.puts("[dolphin] shadow ball store: charged=#{charged?} cancel_state=#{cancelled?}")
        assert charged?
        assert cancelled?

        # --- Fire the stored ball: a projectile must exist.
        probe = settle(probe)

        {probe, fired?} =
          run_tech(
            probe,
            Tech.new(:shadow_ball_fire, :mewtwo),
            90,
            fn acc, p -> acc or p.action == @neutral_b_fire end,
            false
          )

        {probe, fired_types} =
          Enum.reduce(1..30, {probe, MapSet.new()}, fn _i, {probe, acc} ->
            probe = Probe.step!(probe)
            types = Probe.gamestate(probe).projectiles |> Enum.map(& &1.type)
            {probe, Enum.into(types, acc)}
          end)

        IO.puts(
          "[dolphin] shadow ball fire: released=#{fired?} projectile types=#{inspect(MapSet.to_list(fired_types))}"
        )

        assert fired?
        assert MapSet.size(fired_types) > 0

        # --- Teledgehog: from near the edge, hop out past FD's lip
        # (85.57) facing the stage, sink below it, teleport up through
        # the grab zone.
        probe = settle(probe)
        probe = walk_until(probe, 0.72, fn x -> x > 78.0 end)
        probe = settle(probe)

        {probe, {hung?, trace}} =
          run_tech(
            probe,
            Tech.new(:teledgehog, :mewtwo, direction: :right),
            150,
            fn {a, tr}, p ->
              entry = {p.action, Float.round(p.position.x, 1), Float.round(p.position.y, 1)}

              {a or p.action in [@edge_catch, @edge_hanging],
               if(tr == [] or elem(hd(tr), 0) != p.action, do: [entry | tr], else: tr)}
            end,
            {false, []}
          )

        IO.puts(
          "[dolphin] teledgehog: hung=#{hung?} trace=#{inspect(Enum.reverse(trace), base: :hex)}"
        )

        assert hung?

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
        slippi_port: 52_073,
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
      character: Enums.Character.to_id(:mewtwo),
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

  defp run_tech(probe, tech, budget, fold, acc0) do
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

  # Mewtwo's idle fidgets: settle on "grounded and actionable-ish".
  defp settle(probe) do
    Melee.Controller.release_all(probe.controllers[1])

    Probe.until!(
      probe,
      fn p ->
        player = Probe.gamestate(p).players[1]
        player != nil and player.on_ground and player.action < 0x40 and player.hitlag_left == 0
      end,
      fn p ->
        Melee.Controller.release_all(p.controllers[1])
        p
      end,
      timeout_frames: 900
    )
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
      timeout_frames: 900
    )
  end
end
