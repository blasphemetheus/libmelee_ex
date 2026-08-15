defmodule Melee.Integration.CssPortsTest do
  use ExUnit.Case

  @moduledoc """
  Codifies the 2026-08-14 live measurement of the character select
  screen's per-port geometry (`docs/melee-menus.md`), so a regression in
  any of the three coordinate systems fails a rerunnable test instead of
  a live session:

    * HMN/CPU box and CPU slider — validated end-to-end by configuring
      port 2 as a level-5 CPU (box at 15.82 pitch, slider at 15.4);
    * the name box and its tag list — validated on ports 2-4 via the
      yank signature: opening the list pulls the hand up into the rows
      and pins x at exactly `-25.2 + 15.4*(N-1)`. The name box uses the
      15.4 slider pitch, NOT the 15.82 box pitch — the discovery that
      motivated the measurement session.

  Runs windowless on the ExiAI build:

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_css
  """

  alias Melee.{Enums, Probe}

  @moduletag :dolphin
  @moduletag :dolphin_css
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_css_ports_it")

  @name_box_spacing 15.4
  @pinned_column_base -25.2

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

  test "ports 2-4 CSS geometry: name-box spacing, tag-list columns, CPU config", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      windowed? = System.get_env("MELEE_WINDOWED") == "1"
      fox = Enums.Character.to_id(:fox)
      fd = Enums.Stage.to_id(:final_destination)

      probe =
        Probe.start!(
          path: ctx.path,
          iso_path: ctx.iso,
          home: @home,
          slippi_port: 51_597,
          headless: not windowed?,
          gfx_backend: if(windowed?, do: "OGL", else: "Null"),
          ports: [1, 2, 3, 4]
        )

      try do
        probe = Probe.navigate!(probe, port: 1, character: fox, stage: fd, timeout_frames: 8_000)

        # One port at a time — cross-port CSS flows interleaved is the
        # documented trap (docs/melee-menus.md "Sequence cross-port
        # flows").
        probe =
          Enum.reduce([2, 3, 4], probe, fn port, probe ->
            # A panel is inert until its port locks a character in — the
            # name box does not exist before this.
            opts = [port: port, character: fox, stage: fd]

            probe =
              Probe.drive!(probe, &Probe.port_configured?(&1, opts), opts,
                timeout_frames: 6_000,
                describe: "port #{port} character pick"
              )

            # Open the tag list from the measured name-box aim point.
            aim_x = -23.2 + @name_box_spacing * (port - 1)

            probe =
              Probe.goto!(probe, aim_x, -18.62, port: port, tolerance: 0.3, timeout_frames: 1_200)

            probe = Probe.tap!(probe, :a, port: port)

            # The yank signature: the open list pulls the hand up into
            # the rows...
            {_x, y} = Probe.cursor(probe, port)
            assert y > -15.0, "port #{port}: no yank after A at #{aim_x} (y=#{y})"

            # ...and pins x at the port's list column. The pin is
            # ONE-SIDED (found writing this test): rightward motion
            # stops exactly at the column, leftward is free. So always
            # tilt RIGHT — every column (max 21.0 at port 4) sits well
            # left of the screen edge at 26.
            probe = Probe.tilt!(probe, 1.0, 0.5, 12, port: port)
            {x, _y} = Probe.cursor(probe, port)
            expected_column = @pinned_column_base + @name_box_spacing * (port - 1)

            assert_in_delta x, expected_column, 0.4

            # Close the list by selecting row 1 (the current name).
            probe = Probe.goto!(probe, nil, -6.3, port: port, timeout_frames: 600)
            probe = Probe.tap!(probe, :a, port: port)
            probe = Probe.idle!(probe, 10)

            IO.puts("[dolphin] port #{port}: yank ok, column #{Float.round(x, 2)}")
            probe
          end)

        # HMN/CPU box (15.82 pitch) + slider (15.4 pitch), end-to-end:
        # only the level readout can prove both coordinates together.
        cpu_opts = [port: 2, character: fox, stage: fd, cpu_level: 5]

        probe =
          Probe.drive!(probe, &Probe.port_configured?(&1, cpu_opts), cpu_opts,
            timeout_frames: 8_000,
            describe: "port 2 configured as cpu 5"
          )

        p2 = Probe.gamestate(probe).players[2]
        assert p2.cpu_level == 5
        assert p2.controller_status == Enums.ControllerStatus.to_id(:controller_cpu)

        IO.puts("\n[dolphin] css_ports: #{Probe.elapsed_ms(probe)}ms steps=#{probe.frames}")
      after
        Probe.stop(probe)
      end
    end
  end
end
