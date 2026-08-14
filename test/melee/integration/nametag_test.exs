defmodule Melee.Integration.NametagTest do
  use ExUnit.Case

  @moduledoc """
  End-to-end check of in-game nametags against a real Dolphin, driven by
  `Melee.Probe`.

  Excluded by default; it launches Dolphin itself. Point it at an install
  and an ISO, then:

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/netplay/Slippi_Online-x86_64.AppImage \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_nametag

  The first test wipes its user directory, so it also covers the two
  things that make a nametag possible at all: `Melee.Dolphin`
  provisioning a GCI-folder memory card, and `Melee.MenuHelper`
  answering Melee's "Create Game Data?" boot prompt.
  """

  alias Melee.{Dolphin, Enums, Probe}

  @moduletag :dolphin
  @moduletag :dolphin_nametag
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_nametag_it")
  @tag_text "EXPH"

  # A smoke check that these runs are not vacuous: launching Dolphin and
  # connecting the console alone costs seconds, so a "pass" faster than
  # this never drove the game at all. Measured runs land at 8-11s, hence
  # the floor rather than something tighter.
  #
  # Wall clock, NOT `probe.frames`: that counts console steps, which
  # polling coalesces, so it reads far lower than the emulated frames
  # (a full boot-and-navigate is only ~250-350 steps).
  @min_run_ms 5_000

  setup_all do
    path = System.get_env("MELEE_DOLPHIN_PATH")
    iso = System.get_env("MELEE_ISO_PATH")

    if path == nil or iso == nil do
      {:ok, skip: "set MELEE_DOLPHIN_PATH and MELEE_ISO_PATH"}
    else
      {:ok, path: Path.expand(path), iso: Path.expand(iso)}
    end
  end

  # Headless by default so a test run doesn't take over the desktop;
  # MELEE_WINDOWED=1 renders a window when you want to watch.
  defp start_probe(ctx, ports) do
    windowed? = System.get_env("MELEE_WINDOWED") == "1"

    transport =
      case System.get_env("MELEE_TRANSPORT") do
        "nif" -> Melee.Transport.EnetNif
        _ -> Melee.Transport.EnetBeam
      end

    Probe.start!(
      path: ctx.path,
      iso_path: ctx.iso,
      home: @home,
      slippi_port: 51_599,
      headless: not windowed?,
      gfx_backend: if(windowed?, do: "OGL", else: "Null"),
      memory_card: :folder,
      blocking_input: false,
      ports: ports,
      console: [transport: transport]
    )
  end

  # The create flow, callable from either test: ExUnit shuffles tests
  # within a module, so "select" can run first — it must be able to
  # provision the tag (and a clean home) itself rather than relying on
  # test order. A home left behind by a killed run can also be corrupt
  # enough that Dolphin dies at boot (observed: instant :epipe on the
  # controller fifo), which the wipe also cures.
  defp create_tag!(ctx) do
    File.rm_rf!(@home)

    probe = start_probe(ctx, [1])

    try do
      assert File.dir?(Dolphin.gci_folder_path(@home)),
             "Dolphin should have provisioned the GCI folder card"

      probe =
        Probe.drive!(probe, &Probe.helper(&1).nametag_done, bot_opts(:create),
          timeout_frames: 12_000,
          describe: "the nametag to be created"
        )

      assert Probe.helper(probe).nametag_done
      probe
    after
      Probe.stop(probe)
    end
  end

  defp saved_gci, do: Path.wildcard(Path.join(Dolphin.gci_folder_path(@home), "*.gci"))

  defp bot_opts(mode) do
    [
      port: 1,
      character: Enums.Character.to_id(:fox),
      stage: Enums.Stage.to_id(:final_destination),
      nametag: @tag_text,
      nametag_mode: mode
    ]
  end

  test "creates a nametag on a freshly provisioned memory card", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      # create_tag! wipes the home, so this also covers Melee's boot
      # prompt: the helper cannot reach the CSS while the game is stuck
      # on the "Create Game Data?" dialog.
      probe = create_tag!(ctx)

      assert Probe.helper(probe).seen_known_menu

      # Melee writes the tag into its save file on the card. The card
      # folder was wiped at the top of this test, so a .gci existing at
      # all proves the game booted far enough to save.
      assert [gci] = saved_gci()
      assert File.stat!(gci).size > 0

      # Without this, a bug that made `nametag_done` true immediately
      # would sail through every assertion above.
      assert Probe.elapsed_ms(probe) > @min_run_ms,
             "expected a real boot-and-navigate, finished in " <>
               "#{Probe.elapsed_ms(probe)}ms"

      IO.puts(
        "\n[dolphin] create: #{Probe.elapsed_ms(probe)}ms " <>
          "steps=#{probe.frames} gci=#{File.stat!(gci).size}"
      )
    end
  end

  test "selects the saved nametag and it lands in GAME_START", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      # Test order is shuffled, so provision the tag ourselves when the
      # card doesn't hold one yet.
      if saved_gci() == [], do: create_tag!(ctx)

      # A match needs a second player, so port 2 gets a CPU.
      probe = start_probe(ctx, [1, 2])

      cpu_opts = [
        port: 2,
        character: Enums.Character.to_id(:falco),
        stage: Enums.Stage.to_id(:final_destination),
        cpu_level: 9
      ]

      try do
        probe =
          Probe.drive!(
            probe,
            &Probe.at_menu?(&1, :in_game),
            fn probe ->
              # Two gates, same reason: READY TO FIGHT comes up the
              # instant port 2 is filled, well before its CPU level is
              # dragged into place.
              #
              # 1. Hold START at the CSS until port 2 is genuinely
              #    configured (autostart).
              # 2. Hold the NAMETAG flow until then too: opening the tag
              #    list/keyboard interrupts the CSS, and Melee relocates
              #    every other hand to the top of its panel — a port
              #    mid-slider-drag gets yanked off one level short (a
              #    live 9-became-8 stall; the autostart gate then
              #    correctly never opens, and the run sits forever).
              #    Sequence the flows, never interleave them.
              # Like autostart?, the nametag gate may only bite AT the
              # CSS: past it (stage select, loading) the gamestate stops
              # reporting port 2's CSS fields, so port_configured?/2
              # reads false there — and withholding the opts then strips
              # `autostart`, which MenuHelper needs to navigate the
              # stage select at all (a live stall found the hard way).
              cpu_ready? =
                not Probe.at_character_select?(probe) or
                  Probe.port_configured?(probe, cpu_opts)

              bot =
                if cpu_ready? do
                  bot_opts(:select) ++ [autostart: Probe.autostart?(probe, [cpu_opts])]
                else
                  Keyword.drop(bot_opts(:select), [:nametag, :nametag_mode])
                end

              [bot, cpu_opts]
            end,
            timeout_frames: 20_000,
            describe: "the match to start"
          )

        # The nametag is parsed off the GAME_START event.
        assert probe.gamestate.players[1].nametag == @tag_text

        # We really played through the menus to get here, and the CPU
        # was fully configured before the match was allowed to start.
        assert Probe.elapsed_ms(probe) > @min_run_ms,
               "expected a real boot-and-navigate, finished in " <>
                 "#{Probe.elapsed_ms(probe)}ms"

        assert probe.gamestate.players[2].cpu_level == 9

        IO.puts("\n[dolphin] select: #{Probe.elapsed_ms(probe)}ms steps=#{probe.frames}")
      after
        Probe.stop(probe)
      end
    end
  end
end
