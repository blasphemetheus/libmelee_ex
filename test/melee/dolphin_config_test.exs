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

  describe "declare_ports/2" do
    test "undeclared ports are explicitly unplugged (no adapter claim)", %{home: home} do
      assert {:ok, pipes} = DolphinConfig.declare_ports(home, %{1 => :standard, 2 => :standard})

      # Both bot ports get pipes...
      assert Map.keys(pipes) == [1, 2]
      assert pipes[1] == DolphinConfig.pipes_path(home, 1)

      # ...and EVERY port has an explicit SIDevice: 3/4 unplugged, so a
      # template or prior session can't leave the GC adapter configured.
      dolphin = File.read!(Path.join([home, "Config", "Dolphin.ini"]))
      assert dolphin =~ "SIDevice0 = 6"
      assert dolphin =~ "SIDevice1 = 6"
      assert dolphin =~ "SIDevice2 = 0"
      assert dolphin =~ "SIDevice3 = 0"
      refute dolphin =~ "= 12"
    end

    test "overwrites an inherited adapter claim on an undeclared port", %{home: home} do
      config_dir = Path.join(home, "Config")
      File.mkdir_p!(config_dir)

      # What libmelee's template leaves behind: ports 3/4 on the adapter.
      File.write!(Path.join(config_dir, "Dolphin.ini"), """
      [Core]
      SIDevice2 = 12
      SIDevice3 = 12
      """)

      assert {:ok, _} = DolphinConfig.declare_ports(home, %{1 => :standard})

      dolphin = File.read!(Path.join(config_dir, "Dolphin.ini"))
      assert dolphin =~ "SIDevice2 = 0"
      assert dolphin =~ "SIDevice3 = 0"
      refute dolphin =~ "= 12"
    end

    test "a declared adapter port keeps the adapter (human showcase)", %{home: home} do
      assert {:ok, pipes} =
               DolphinConfig.declare_ports(home, %{1 => :standard, 2 => :gcn_adapter})

      # Only the pipe port comes back; the adapter port has no fifo.
      assert Map.keys(pipes) == [1]

      dolphin = File.read!(Path.join([home, "Config", "Dolphin.ini"]))
      assert dolphin =~ "SIDevice0 = 6"
      assert dolphin =~ "SIDevice1 = 12"
      assert dolphin =~ "SIDevice2 = 0"
      assert dolphin =~ "SIDevice3 = 0"
    end
  end
end
