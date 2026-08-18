defmodule Melee.Integration.DeterminismTest do
  use ExUnit.Case

  @moduledoc """
  Bit-reproducible episodes: `single_core: true` + `custom_rtc:` +
  lockstep direct inputs make two runs with the same input schedule
  produce the SAME match — same GAME_START random seed and an
  identical frame-by-frame fingerprint (positions, percents, and
  RNG-driven item spawns at very-high frequency). A different
  `custom_rtc` value picks a different seed: the RTC is the episode
  seed selector (Melee derives its seed from emulated boot state; the
  0xBC generator only feeds netplay-side draws).

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_determinism
  """

  alias Melee.{Console, Controller, GameState, Match, Session}

  @moduletag :dolphin
  @moduletag :dolphin_determinism
  @moduletag timeout: 600_000

  @rtc 946_684_800
  @fingerprint_frames 300

  setup_all do
    path = System.get_env("MELEE_DOLPHIN_PATH")
    iso = System.get_env("MELEE_ISO_PATH")

    if path == nil or iso == nil do
      {:ok, skip: "set MELEE_DOLPHIN_PATH and MELEE_ISO_PATH"}
    else
      {:ok, path: Path.expand(path), iso: Path.expand(iso)}
    end
  end

  test "same RTC reproduces the match bit-for-bit; a different RTC does not", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      {seed_a, print_a} = episode(ctx, "a", 51_911, @rtc)
      {seed_b, print_b} = episode(ctx, "b", 51_913, @rtc)
      {seed_c, print_c} = episode(ctx, "c", 51_915, @rtc + 1)

      assert seed_a == seed_b, "same RTC produced different seeds: #{seed_a} vs #{seed_b}"

      assert print_a == print_b,
             "same seed diverged in play — determinism recipe is broken"

      refute seed_c == seed_a, "RTC+1 failed to select a different seed"
      refute print_c == print_a

      IO.puts(
        "\n[dolphin] determinism: seed #{seed_a} reproduced " <>
          "(fingerprint #{Base.encode16(binary_part(print_a, 0, 8))}); " <>
          "RTC+1 -> seed #{seed_c}"
      )
    end
  end

  # One full episode: boot with the determinism recipe, play
  # @fingerprint_frames frames of a frame-keyed schedule in a
  # very-high-items match, return {game seed, fingerprint hash}.
  defp episode(ctx, name, slippi_port, rtc) do
    home = Path.join(System.tmp_dir!(), "libmelee_ex_determinism_#{name}")
    File.rm_rf!(home)

    {:ok, session} =
      Session.start_link(
        path: ctx.path,
        iso_path: ctx.iso,
        home: home,
        slippi_port: slippi_port,
        headless: true,
        gfx_backend: "Null",
        blocking_input: true,
        exi_inputs: true,
        ffw: true,
        direct_inputs: true,
        single_core: true,
        custom_rtc: rtc,
        ports: [1, 2],
        console: [polling_mode: true, polling_timeout: 100]
      )

    {:ok, first} =
      Match.play(session,
        rules: [item_frequency: :very_high],
        p1: [character: :fox],
        p2: [character: :falco],
        stage: :final_destination
      )

    assert GameState.in_game?(first)
    controller = Session.controller(session, 1)
    console = Session.console(session)

    rows = collect(console, controller, [], 0)
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(Enum.reverse(rows)))

    :ok = Session.stop(session)
    {first.random_seed, hash}
  end

  defp collect(_console, _controller, rows, n) when n >= @fingerprint_frames, do: rows

  defp collect(console, controller, rows, n) do
    case Console.step(console) do
      {:ok, gs} ->
        # Frame-keyed schedule — identical across runs by construction.
        phase = rem(gs.frame, 120)

        cond do
          phase < 40 -> Controller.tilt_analog(controller, :main, 1.0, 0.5)
          phase < 80 -> Controller.tilt_analog(controller, :main, 0.0, 0.5)
          true -> Controller.release_all(controller)
        end

        if rem(gs.frame, 30) == 0,
          do: Controller.press_button(controller, :a),
          else: Controller.release_button(controller, :a)

        if gs.frame >= 0 do
          p1 = gs.players[1]
          p2 = gs.players[2]

          projectiles =
            Enum.map(gs.projectiles, fn pr ->
              {pr.type, Float.round(pr.position.x, 3), Float.round(pr.position.y, 3)}
            end)

          row =
            {gs.frame, Float.round(p1.position.x, 3), Float.round(p1.position.y, 3), p1.percent,
             Float.round(p2.position.x, 3), p2.percent, projectiles}

          collect(console, controller, [row | rows], n + 1)
        else
          collect(console, controller, rows, n)
        end

      _ ->
        collect(console, controller, rows, n)
    end
  end
end
