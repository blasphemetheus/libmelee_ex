defmodule Melee.Integration.TechCharactersTest do
  use ExUnit.Case

  @moduledoc """
  Character kits, live: Peach's float cancel (actionable ~2 frames
  after touchdown), Falcon's gentleman + instant RAR, Marth's pivot
  fsmash, Samus's missile land-cancel (~2 frames), and the Ice
  Climbers grab desync (Nana blizzards solo while Popo holds).

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_characters
  """

  alias Melee.{Enums, Probe, Tech}

  @moduletag :dolphin
  @moduletag :dolphin_characters
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_chars_it")

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

  test "Peach float and float-aerial (landing lag measured)", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_091, :peach)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        nair = Enums.Action.to_id(:nair)
        nair_landing = Enums.Action.to_id(:nair_landing)

        # Control: SHFFL machinery without the L pulse — a plain
        # falling nair's landing lag.
        {probe, _} =
          run_tech(
            probe,
            Tech.new(:shffl, :peach, aerial: :nair, l_cancel: false),
            120,
            fn a, _ -> a end,
            nil
          )

        {probe, control_lag} = count_landing_lag(probe, nair_landing)
        probe = settle(probe)

        _ = nair

        {probe, {floated?, attacked?}} =
          run_tech(
            probe,
            Tech.new(:float_cancel, :peach, aerial: :nair),
            120,
            fn {fl, a}, p ->
              {fl or p.action == 0x155, a or p.action in 0x158..0x15C}
            end,
            {false, false}
          )

        # The FC touchdown is a plain 4-frame landing — measure
        # ACTIONABILITY (a held movement input taking effect), not the
        # idle landing animation.
        {probe, fc_lag} =
          Enum.reduce_while(1..40, {probe, 0}, fn _i, {probe, n} ->
            Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.0, 0.5)
            probe = Probe.step!(probe)
            p = player(probe)

            if p.action in [0x0F, 0x10, 0x11, 0x12, 0x14],
              do: {:halt, {probe, n}},
              else: {:cont, {probe, n + 1}}
          end)

        Melee.Controller.release_all(probe.controllers[1])

        IO.puts(
          "\n[dolphin] peach FC nair: floated=#{floated?} attacked=#{attacked?} actionable_in=#{fc_lag} (plain nair anim=#{inspect(control_lag)})"
        )

        assert floated?
        assert attacked?
        assert fc_lag <= 7
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Falcon gentleman: jab3 without the rapid jab", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_093, :cptfalcon)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        {probe, {jab3?, rapid?}} =
          run_tech(
            probe,
            Tech.new(:gentleman, :cptfalcon),
            120,
            fn {j3, rp}, p -> {j3 or p.action == 0x2E, rp or p.action == 0x2F} end,
            {false, false}
          )

        IO.puts("\n[dolphin] gentleman: jab3=#{jab3?} rapid=#{rapid?}")
        assert jab3?
        refute rapid?

        # --- Instant RAR: run, turnaround jump, bair drifting the
        # original way.
        probe = settle(probe)
        f0 = player(probe).facing
        dir = if f0, do: :right, else: :left
        x0 = player(probe).position.x
        bair = Enums.Action.to_id(:bair)

        {probe, {bair?, flipped_at_bair?}} =
          run_tech(
            probe,
            Tech.new(:instant_rar, :cptfalcon, direction: dir),
            90,
            fn {b, fl}, p ->
              hit = p.action == bair
              {b or hit, fl or (hit and p.facing != f0)}
            end,
            {false, false}
          )

        drift = player(probe).position.x - x0
        drift = if dir == :right, do: drift, else: -drift

        IO.puts(
          "[dolphin] instant RAR: bair=#{bair?} facing_flipped_at_bair=#{flipped_at_bair?} run-direction drift=#{Float.round(drift, 1)}"
        )

        assert bair?
        assert flipped_at_bair?
        assert drift > 2.0
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Marth pivot fsmash", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_095, :marth)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)
        f0 = player(probe).facing
        dir = if f0, do: :right, else: :left

        {probe, {flipped?, fsmash?}} =
          run_tech(
            probe,
            Tech.new(:pivot_smash, :marth, direction: dir),
            60,
            fn {fl, fs}, p ->
              {fl or p.facing != f0, fs or p.action in 0x3A..0x3E}
            end,
            {false, false}
          )

        IO.puts("\n[dolphin] pivot fsmash: facing_flipped=#{flipped?} fsmash=#{fsmash?}")
        assert flipped?
        assert fsmash?
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Samus missile land-cancel: actionable ~2 frames after touchdown", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_097, :samus)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)
        f0 = player(probe).facing
        dir = if f0, do: :right, else: :left

        {probe, missile?} =
          run_tech(
            probe,
            Tech.new(:missile_cancel, :samus, direction: dir),
            120,
            fn a, _ -> a end,
            false
          )
          |> then(fn {probe, _} ->
            {probe, Probe.gamestate(probe).projectiles != []}
          end)

        # The routine ends on touchdown; measure ACTIONABILITY by
        # holding a movement input and counting frames until it takes
        # (the landing ANIMATION runs ~30 frames when idle, but it is
        # interruptible — the original "heavy landing" reading was
        # that artifact; the missile land-cancel is real).
        {probe, lag} =
          Enum.reduce_while(1..40, {probe, 0}, fn _i, {probe, n} ->
            Melee.Controller.tilt_analog(probe.controllers[1], :main, 0.0, 0.5)
            probe = Probe.step!(probe)
            p = player(probe)

            if p.action in [0x0F, 0x10, 0x11, 0x12, 0x14],
              do: {:halt, {probe, n}},
              else: {:cont, {probe, n + 1}}
          end)

        Melee.Controller.release_all(probe.controllers[1])
        IO.puts("\n[dolphin] sh missile: missile=#{missile?} actionable_in=#{lag} frames")
        assert missile?
        assert lag <= 8
        _ = probe
      after
        Probe.stop(probe)
      end
    end
  end

  test "Ice Climbers grab desync: Nana blizzards while Popo holds", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      probe = boot(ctx, 52_099, :popo)

      try do
        probe = Probe.idle!(probe, 90)
        probe = settle(probe)

        {probe, desynced?, pair, trace} = ics_attempt(probe, 3)

        IO.puts(
          "\n[dolphin] ICs grab desync: desynced=#{desynced?} popo/nana=#{inspect(pair, base: :hex)} trace=#{inspect(trace, base: :hex, limit: 25)}"
        )

        assert desynced?
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

  defp ics_attempt(probe, attempts) do
    probe = settle(probe)
    falco_x = Probe.gamestate(probe).players[2].position.x
    me_x = player(probe).position.x
    tilt = if falco_x > me_x, do: 0.72, else: 0.28
    probe = walk_until(probe, tilt, fn x -> abs(x - falco_x) < 7.0 end)
    probe = settle(probe)

    {probe, {desynced?, pair, trace}} =
      run_tech(
        probe,
        Tech.new(:ics_desync, :popo),
        90,
        fn {d, pr, tr}, p ->
          nana = p.nana
          na = nana && nana.action
          split? = na != nil and p.action in [0xD5, 0xD8] and na >= 0x155

          tr =
            if tr == [] or hd(tr) != {p.action, na}, do: [{p.action, na} | tr], else: tr

          {d or split?, if(split?, do: {p.action, na}, else: pr), tr}
        end,
        {false, nil, []}
      )

    probe = wait_actionable(probe)

    cond do
      desynced? -> {probe, true, pair, Enum.reverse(trace)}
      attempts > 1 -> ics_attempt(probe, attempts - 1)
      true -> {probe, false, pair, Enum.reverse(trace)}
    end
  end

  # Post-grab: wait until both ports are grounded and actionable.
  defp wait_actionable(probe) do
    Melee.Controller.release_all(probe.controllers[1])

    Probe.until!(
      probe,
      fn p ->
        a = Probe.gamestate(p).players[1]
        b = Probe.gamestate(p).players[2]
        a != nil and b != nil and a.on_ground and a.action < 0x40 and b.action < 0x40
      end,
      fn p ->
        Melee.Controller.release_all(p.controllers[1])
        p
      end,
      timeout_frames: 900
    )
  end

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

  # Frames spent in the given landing action(s) after a routine ends.
  defp count_landing_lag(probe, landing_action) do
    actions = List.wrap(landing_action)

    Enum.reduce_while(1..50, {probe, 0}, fn _i, {probe, lag} ->
      p = player(probe)

      cond do
        p.action in actions -> {:cont, {Probe.step!(probe), lag + 1}}
        lag > 0 -> {:halt, {probe, lag}}
        true -> {:cont, {Probe.step!(probe), lag}}
      end
    end)
    |> then(fn {probe, lag} -> {probe, if(lag == 0, do: nil, else: lag)} end)
  end

  defp settle(probe) do
    Melee.Controller.release_all(probe.controllers[1])

    Probe.until!(
      probe,
      fn p ->
        pl = Probe.gamestate(p).players[1]
        pl != nil and pl.on_ground and pl.action == 0x0E and pl.hitlag_left == 0
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
        pl = Probe.gamestate(p).players[1]
        pl != nil and done?.(pl.position.x)
      end,
      fn p ->
        Melee.Controller.tilt_analog(p.controllers[1], :main, tilt_x, 0.5)
        p
      end,
      timeout_frames: 900
    )
  end
end
