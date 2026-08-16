defmodule Melee.Integration.MultishineTest do
  use ExUnit.Case

  @moduledoc """
  Frame-perfect input, demonstrated: Fox multishines in a live match.

  A multishine is a jump-cancelled shine loop — shine, jump out of it,
  shine again on jumpsquat frame 3 — with zero slack: pressing B one
  frame early or late breaks the chain. Sustaining it for hundreds of
  frames is simultaneously a capability demo, a frame-accuracy proof
  (the loop reads `action_frame` and reacts same-frame), and a latency
  regression canary. The logic is a direct port of Python libmelee's
  canonical `multishine` example.

  Runs windowless on the ExiAI build:

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_tech
  """

  alias Melee.{Controller, Enums, Probe}

  @moduletag :dolphin
  @moduletag :dolphin_tech
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_multishine_it")

  @standing Enums.Action.to_id(:standing)
  @knee_bend Enums.Action.to_id(:knee_bend)
  @shine_ground_start Enums.Action.to_id(:down_b_ground_start)
  @shine_ground Enums.Action.to_id(:down_b_ground)
  @shine_stun Enums.Action.to_id(:down_b_stun)
  @shine_air Enums.Action.to_id(:down_b_air)

  @shine_states MapSet.new([@shine_ground_start, @shine_air])

  # Frames of live play to count over, and the floors that prove a
  # sustained loop rather than a lucky shine or B-mashing: the measured
  # steady cycle is 8 frames (74 shines / 73 jumpsquats per 600), and
  # every re-shine passes through jumpsquat, so shine entries and
  # knee-bend entries must BOTH accumulate. Floors leave ~20% slack for
  # a slow start, not for a broken loop.
  @play_frames 600
  @min_shines 60
  @min_jumpsquats 55

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

  test "Fox sustains a multishine loop in a live match", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"

      probe =
        Probe.start!(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_596,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          # Load-bearing twice over: the ExiAI build ignores in-game
          # pipe input without blocking pipes, and blocking is what
          # paces Dolphin to one frame per step — a frame-perfect loop
          # cannot afford coalesced frames.
          blocking_input: true,
          ports: [1, 2]
        )

      bot_opts = [
        port: 1,
        character: Enums.Character.to_id(:fox),
        stage: Enums.Stage.to_id(:final_destination)
      ]

      # Port 2 is an IDLE HUMAN, not a CPU: a level-1 CPU walks over and
      # breaks the loop (first calibration run: Fox spent 293 of 600
      # frames dead or respawning). An idle human panel fills the match
      # and then stands at spawn forever.
      dummy_opts = [
        port: 2,
        character: Enums.Character.to_id(:falco),
        stage: Enums.Stage.to_id(:final_destination)
      ]

      try do
        probe =
          Probe.drive!(
            probe,
            &Probe.at_menu?(&1, :in_game),
            fn probe ->
              [
                bot_opts ++ [autostart: Probe.autostart?(probe, [dummy_opts])],
                dummy_opts
              ]
            end,
            timeout_frames: 20_000,
            describe: "the match to start"
          )

        # Let the entry animation and GO! pass.
        probe = Probe.idle!(probe, 90)

        controller = probe.controllers[1]

        {probe, actions} =
          Enum.reduce(1..@play_frames, {probe, []}, fn _i, {probe, actions} ->
            probe =
              Probe.advance!(probe, 1, fn probe ->
                multishine(Probe.gamestate(probe).players[1], controller)
                probe
              end)

            {probe, [Probe.gamestate(probe).players[1].action | actions]}
          end)

        actions = Enum.reverse(actions)

        shines = entries(actions, @shine_states)
        jumpsquats = entries(actions, MapSet.new([@knee_bend]))

        IO.puts(
          "\n[dolphin] multishine: #{Probe.elapsed_ms(probe)}ms " <>
            "shines=#{shines} jumpsquats=#{jumpsquats} over #{@play_frames} frames"
        )

        assert shines >= @min_shines,
               "only #{shines} shine entries in #{@play_frames} frames — not a sustained loop"

        assert jumpsquats >= @min_jumpsquats,
               "only #{jumpsquats} jumpsquat entries — shines were not jump-cancelled"
      after
        Probe.stop(probe)
      end
    end
  end

  # Count transitions INTO the given action set.
  defp entries(actions, set) do
    actions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> not MapSet.member?(set, a) and MapSet.member?(set, b) end)
  end

  # Python libmelee's canonical multishine, ported: shine from standing;
  # in jumpsquat, shine exactly on frame 3; once a grounded shine is
  # jump-cancellable (frame >= 3), press jump; otherwise neutral.
  defp multishine(p, controller) do
    cond do
      p == nil ->
        Controller.release_all(controller)

      p.action == @standing ->
        Controller.press_button(controller, :b)
        Controller.tilt_analog(controller, :main, 0.5, 0.0)

      p.action == @knee_bend and p.action_frame == 3 ->
        Controller.press_button(controller, :b)
        Controller.tilt_analog(controller, :main, 0.5, 0.0)

      p.action == @knee_bend ->
        Controller.release_button(controller, :b)

      p.action in [@shine_ground_start, @shine_stun] and p.action_frame >= 3 and p.on_ground ->
        Controller.release_button(controller, :b)
        Controller.press_button(controller, :y)

      p.action == @shine_ground ->
        Controller.press_button(controller, :y)

      true ->
        Controller.release_all(controller)
    end
  end
end
