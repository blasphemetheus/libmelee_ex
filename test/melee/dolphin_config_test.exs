defmodule Melee.DolphinConfigTest do
  use ExUnit.Case, async: true

  alias Melee.DolphinConfig

  setup ctx do
    home = Path.join(System.tmp_dir!(), "melee_home_#{:erlang.phash2(ctx.test)}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    {:ok, home: home}
  end

  test "pipes_path follows libmelee's convention", %{home: home} do
    assert DolphinConfig.pipes_path(home, 1) == Path.join([home, "Pipes", "slippibot1"])
    assert DolphinConfig.pipes_path(home, 4) == Path.join([home, "Pipes", "slippibot4"])
  end

  test "setup_controller creates the fifo and both config entries", %{home: home} do
    assert {:ok, pipe} = DolphinConfig.setup_controller(home, 2)
    assert pipe == DolphinConfig.pipes_path(home, 2)

    # A fifo, not a regular file.
    {:ok, stat} = File.stat(pipe)
    assert stat.type == :other

    pad = File.read!(Path.join([home, "Config", "GCPadNew.ini"]))
    assert pad =~ "[GCPad2]"
    assert pad =~ "Device = Pipe/0/slippibot2"
    assert pad =~ "Main Stick/Up = Axis MAIN Y +"
    assert pad =~ "Triggers/Threshold = 90"

    dolphin = File.read!(Path.join([home, "Config", "Dolphin.ini"]))
    assert dolphin =~ "[Core]"
    assert dolphin =~ "SIDevice1 = 6"
  end

  test "setup preserves unrelated existing config", %{home: home} do
    config_dir = Path.join(home, "Config")
    File.mkdir_p!(config_dir)

    File.write!(Path.join(config_dir, "Dolphin.ini"), """
    [General]
    ISOPath0 = /isos/melee.iso

    [Core]
    SlippiReplayDir = /replays
    """)

    assert {:ok, _} = DolphinConfig.setup_controller(home, 1)

    dolphin = File.read!(Path.join(config_dir, "Dolphin.ini"))
    assert dolphin =~ "ISOPath0 = /isos/melee.iso"
    assert dolphin =~ "SlippiReplayDir = /replays"
    assert dolphin =~ "SIDevice0 = 6"
  end

  test "setup is idempotent", %{home: home} do
    assert {:ok, _} = DolphinConfig.setup_controller(home, 1)
    first = File.read!(Path.join([home, "Config", "GCPadNew.ini"]))
    assert {:ok, _} = DolphinConfig.setup_controller(home, 1)
    assert File.read!(Path.join([home, "Config", "GCPadNew.ini"])) == first
  end

  test "multiple ports coexist in one pad config", %{home: home} do
    assert {:ok, _} = DolphinConfig.setup_controller(home, 1)
    assert {:ok, _} = DolphinConfig.setup_controller(home, 2)

    pad = File.read!(Path.join([home, "Config", "GCPadNew.ini"]))
    assert pad =~ "[GCPad1]"
    assert pad =~ "[GCPad2]"
    assert pad =~ "Device = Pipe/0/slippibot1"
    assert pad =~ "Device = Pipe/0/slippibot2"
  end

  test "unplugged type writes SIDevice 0 and no pipe device", %{home: home} do
    assert {:ok, _} = DolphinConfig.setup_controller(home, 3, :unplugged)

    dolphin = File.read!(Path.join([home, "Config", "Dolphin.ini"]))
    assert dolphin =~ "SIDevice2 = 0"

    pad = File.read!(Path.join([home, "Config", "GCPadNew.ini"]))
    assert pad =~ "[GCPad3]"
    refute pad =~ "Pipe/0/slippibot3"
  end
end
