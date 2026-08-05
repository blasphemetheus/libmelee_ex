defmodule Melee.DolphinTest do
  use ExUnit.Case, async: true

  alias Melee.Dolphin

  @moduletag :tmp_dir

  defp fake_exe(dir, name \\ "dolphin-emu-headless") do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\nsleep 30\n")
    File.chmod!(path, 0o755)
    path
  end

  defp read_ini(home), do: File.read!(Path.join([home, "Config", "Dolphin.ini"]))

  describe "resolve_exe/2" do
    test "accepts a direct file path as-is", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      assert {:ok, ^exe, :ishiiruka} = Dolphin.resolve_exe(exe)
    end

    test "resolves an ishiiruka install directory", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "netplay")
      File.mkdir_p!(dir)
      exe = fake_exe(dir, "Slippi_Online-x86_64.AppImage")
      assert {:ok, ^exe, :ishiiruka} = Dolphin.resolve_exe(dir)
    end

    test "resolves a mainline (netplay-beta) install directory", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "netplay-beta")
      File.mkdir_p!(dir)
      exe = fake_exe(dir, "Slippi_Netplay_Mainline-x86_64.AppImage")
      assert {:ok, ^exe, :mainline} = Dolphin.resolve_exe(dir)
    end

    test "explicit flavor overrides path heuristic", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "somedolphin")
      File.mkdir_p!(dir)
      exe = fake_exe(dir, "Slippi_Netplay_Mainline-x86_64.AppImage")
      assert {:ok, ^exe, :mainline} = Dolphin.resolve_exe(dir, :mainline)
    end

    test "errors when the AppImage is missing", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "netplay")
      File.mkdir_p!(dir)
      assert {:error, {:exe_not_found, _}} = Dolphin.resolve_exe(dir)
    end

    test "errors on a nonexistent path", %{tmp_dir: tmp} do
      assert {:error, {:invalid_dolphin_path, _}} =
               Dolphin.resolve_exe(Path.join(tmp, "nope"))
    end
  end

  describe "detect_flavor/1" do
    test "netplay-beta and mainline paths are mainline" do
      assert Dolphin.detect_flavor("/x/Slippi Launcher/netplay-beta") == :mainline
      assert Dolphin.detect_flavor("/x/Slippi_Netplay_Mainline-x86_64.AppImage") == :mainline
    end

    test "everything else falls back to ishiiruka" do
      assert Dolphin.detect_flavor("/x/Slippi Launcher/netplay") == :ishiiruka
      assert Dolphin.detect_flavor("/x/slippi/exi-ai/dolphin-emu-headless") == :ishiiruka
    end
  end

  describe "prepare_home/1 — ishiiruka" do
    test "writes headless spectator config under [Core]", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, prep} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 slippi_port: 12345,
                 headless: true
               )

      assert prep.flavor == :ishiiruka
      assert prep.temp_home? == false
      assert prep.home == home
      assert prep.args == ["-e", "/isos/melee.iso", "-u", home]

      ini = read_ini(home)
      assert ini =~ "[Core]"
      assert ini =~ "SlippiEnableSpectator = True"
      assert ini =~ "SlippiSpectatorLocalPort = 12345"
      assert ini =~ "SlippiOnlineDelay = 0"
      # blocking_input defaults to headless
      assert ini =~ "BlockingPipes = True"
      assert ini =~ "SlippiSaveReplays = False"
      assert ini =~ "GFXBackend = Null"
      assert ini =~ "EmulationSpeed = 1.0"
      assert ini =~ "backgroundinput = True"
      assert ini =~ "Fullscreen = False"
      assert ini =~ "Backend = No audio output"
      # no mainline keys / platform flag
      refute ini =~ "[Slippi]"
      refute "--platform" in prep.args
    end

    test "non-headless defaults: no Null backend, no blocking, no DSP override",
         %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(path: exe, iso_path: "/isos/melee.iso", home: home)

      ini = read_ini(home)
      refute ini =~ "GFXBackend = Null"
      assert ini =~ "BlockingPipes = False"
      refute ini =~ "[DSP]"
    end

    test "explicit options: gfx_backend, replay_dir, online_delay, speed, extra_args",
         %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")
      replay_dir = Path.join(tmp, "replays")

      assert {:ok, prep} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 gfx_backend: "OGL",
                 online_delay: 2,
                 emulation_speed: 0,
                 save_replays: true,
                 replay_dir: replay_dir,
                 blocking_input: true,
                 extra_args: ["--foo"]
               )

      assert File.dir?(replay_dir)
      assert List.last(prep.args) == "--foo"

      ini = read_ini(home)
      assert ini =~ "GFXBackend = OGL"
      assert ini =~ "SlippiOnlineDelay = 2"
      assert ini =~ "EmulationSpeed = 0"
      assert ini =~ "SlippiSaveReplays = True"
      assert ini =~ "SlippiReplayDir = #{replay_dir}"
      assert ini =~ "BlockingPipes = True"
    end
  end

  describe "prepare_home/1 — mainline" do
    test "writes spectator config under [Slippi] and passes --platform headless",
         %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, prep} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 flavor: :mainline,
                 slippi_port: 55555,
                 headless: true
               )

      assert prep.flavor == :mainline
      assert prep.args == ["-e", "/isos/melee.iso", "-u", home, "--platform", "headless"]

      ini = read_ini(home)
      assert ini =~ "[Slippi]"
      assert ini =~ "EnableSpectator = True"
      assert ini =~ "SpectatorLocalPort = 55555"
      assert ini =~ "OnlineDelay = 0"
      assert ini =~ "BlockingPipes = True"
      assert ini =~ "SaveReplays = False"
      assert ini =~ "Backend = No Audio Output"
      # ishiiruka-prefixed keys must not appear
      refute ini =~ "SlippiEnableSpectator"
    end
  end

  describe "gecko codes" do
    test "renders the template with menu-info code and extra codes", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 gecko_extra_codes: ["$Optional: Infinite Time Mode"]
               )

      gecko = File.read!(Path.join([home, "GameSettings", "GALE01r2.ini"]))
      assert gecko =~ "[Gecko_Enabled]"
      assert gecko =~ "$Optional: Extract Menu Info"
      assert gecko =~ "$Optional: Infinite Time Mode"
      refute gecko =~ "{extra_codes}"
    end

    test "setup_gecko_codes: false skips the file", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 setup_gecko_codes: false
               )

      refute File.exists?(Path.join([home, "GameSettings", "GALE01r2.ini"]))
    end
  end

  describe "copy_home_from" do
    test "copies files and subdirectories but skips fifos", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      src = Path.join(tmp, "src_home")
      home = Path.join(tmp, "home")
      File.mkdir_p!(Path.join(src, "Slippi"))
      File.write!(Path.join(src, "top.txt"), "top")
      File.write!(Path.join([src, "Slippi", "user.json"]), "{}")
      fifo = Path.join(src, "slippibot1")
      {_, 0} = System.cmd("mkfifo", [fifo])

      assert {:ok, prep} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 copy_home_from: src
               )

      assert File.read!(Path.join(prep.home, "top.txt")) == "top"
      assert File.read!(Path.join([prep.home, "Slippi", "user.json"])) == "{}"
      refute File.exists?(Path.join(prep.home, "slippibot1"))
    end
  end

  describe "option validation" do
    test "missing required options", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      assert {:error, {:missing_option, :path}} = Dolphin.prepare_home(iso_path: "/x.iso")
      assert {:error, {:missing_option, :iso_path}} = Dolphin.prepare_home(path: exe)
    end
  end

  describe "process lifecycle" do
    test "launch, alive?, stop with a fake executable; temp home deleted",
         %{tmp_dir: tmp} do
      exe = fake_exe(tmp)

      assert {:ok, dolphin} = Dolphin.launch(path: exe, iso_path: "/isos/melee.iso")
      assert %Dolphin{} = dolphin
      assert dolphin.temp_home? == true
      assert is_integer(dolphin.os_pid)
      assert File.dir?(dolphin.home)
      assert Dolphin.alive?(dolphin)

      # config was written into the temp home before launch
      assert File.exists?(Path.join([dolphin.home, "Config", "Dolphin.ini"]))

      assert :ok = Dolphin.stop(dolphin)
      refute Dolphin.alive?(dolphin)
      refute File.exists?(dolphin.home)
    end

    test "pipes_path and setup_controller delegate to DolphinConfig", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      {:ok, prep} = Dolphin.prepare_home(path: exe, iso_path: "/x.iso", home: home)

      dolphin = %Dolphin{
        exe: prep.exe,
        home: prep.home,
        slippi_port: prep.slippi_port,
        flavor: prep.flavor,
        temp_home?: false
      }

      assert Dolphin.pipes_path(dolphin, 2) == Path.join([home, "Pipes", "slippibot2"])
      assert {:ok, pipe} = Dolphin.setup_controller(dolphin, 2)
      assert pipe == Path.join([home, "Pipes", "slippibot2"])
      assert File.exists?(pipe)
    end
  end
end
