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

  defp logger_ini(home), do: Path.join([home, "Config", "Logger.ini"])

  defp user_json(home), do: Path.join([home, "Slippi", "user.json"])

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
                 slippi_port: 12_345,
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

    test "a replay_dir implies save_replays (invariant: a configured dir wants replays)",
         %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")
      replay_dir = Path.join(tmp, "replays")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 replay_dir: replay_dir
               )

      ini = read_ini(home)
      assert ini =~ "SlippiSaveReplays = True"
      assert ini =~ "SlippiReplayDir = #{replay_dir}"
    end

    test "a spectator port held by another process fails fast with a named error",
         %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      {:ok, squatter} = :gen_udp.open(0, [:binary])
      {:ok, port} = :inet.port(squatter)

      try do
        assert {:error, {:spectator_port_in_use, ^port, :eaddrinuse}} =
                 Dolphin.prepare_home(
                   path: exe,
                   iso_path: "/isos/melee.iso",
                   home: Path.join(tmp, "home"),
                   slippi_port: port,
                   # test_helper disables the probe globally (51441 may be
                   # genuinely busy on a dev box); this test IS the probe
                   check_spectator_port: true
                 )
      after
        :gen_udp.close(squatter)
      end
    end

    test "check_spectator_port: false skips the port probe", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      {:ok, squatter} = :gen_udp.open(0, [:binary])
      {:ok, port} = :inet.port(squatter)

      try do
        assert {:ok, prep} =
                 Dolphin.prepare_home(
                   path: exe,
                   iso_path: "/isos/melee.iso",
                   home: Path.join(tmp, "home"),
                   slippi_port: port,
                   check_spectator_port: false
                 )

        assert prep.slippi_port == port
      after
        :gen_udp.close(squatter)
      end
    end

    test "explicit save_replays: false still wins over a replay_dir", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 replay_dir: Path.join(tmp, "replays"),
                 save_replays: false
               )

      assert read_ini(home) =~ "SlippiSaveReplays = False"
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
                 slippi_port: 55_555,
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

  describe "memory card" do
    test "defaults to unplugging both slots", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(path: exe, iso_path: "/isos/melee.iso", home: home)

      ini = read_ini(home)
      assert ini =~ "SlotA = 255"
      assert ini =~ "SlotB = 255"
      refute File.dir?(Dolphin.gci_folder_path(home))
    end

    test "true leaves the slots as the base config has them", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 memory_card: true
               )

      ini = read_ini(home)
      refute ini =~ "SlotA ="
      refute ini =~ "SlotB ="
      refute File.dir?(Dolphin.gci_folder_path(home))
    end

    test ":folder selects the GCI folder device and creates the directory",
         %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 memory_card: :folder
               )

      # EXI device 8 is Dolphin's folder-backed memory card.
      assert read_ini(home) =~ "SlotA = 8"
      assert File.dir?(Dolphin.gci_folder_path(home))
      assert Dolphin.gci_folder_path(home) == Path.join([home, "GC", "USA", "Card A"])
    end

    test "{:folder, seed: path} copies the save in, without clobbering", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")
      seed = Path.join(tmp, "seed.gci")
      File.write!(seed, "fresh save")

      opts = [path: exe, iso_path: "/isos/melee.iso", home: home]

      assert {:ok, _} = Dolphin.prepare_home(opts ++ [memory_card: {:folder, seed: seed}])

      assert read_ini(home) =~ "SlotA = 8"
      target = Path.join(Dolphin.gci_folder_path(home), "seed.gci")
      assert File.read!(target) == "fresh save"

      # A home reused across sessions owns its card contents: the game
      # has since written into the save, and re-seeding must not undo
      # that.
      File.write!(target, "game progress")
      assert {:ok, _} = Dolphin.prepare_home(opts ++ [memory_card: {:folder, seed: seed}])
      assert File.read!(target) == "game progress"
    end

    test ":folder honours :memory_card_region", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/isos/melee.iso",
                 home: home,
                 memory_card: :folder,
                 memory_card_region: "EUR"
               )

      assert File.dir?(Dolphin.gci_folder_path(home, "EUR"))
      refute File.dir?(Dolphin.gci_folder_path(home, "USA"))
    end

    test "rejects a nonsense value", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)

      assert_raise ArgumentError, ~r/:memory_card must be/, fn ->
        Dolphin.prepare_home(
          path: exe,
          iso_path: "/isos/melee.iso",
          home: Path.join(tmp, "home"),
          memory_card: :raw
        )
      end
    end
  end

  describe "option validation" do
    test "missing required options", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      # autodetect: false — otherwise a machine with a Slippi Launcher
      # installed would fill these in (see the autodetection tests).
      assert {:error, {:missing_option, :path}} =
               Dolphin.prepare_home(iso_path: "/x.iso", autodetect: false)

      assert {:error, {:missing_option, :iso_path}} =
               Dolphin.prepare_home(path: exe, autodetect: false)
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

  describe "replay_monthly_folders" do
    test "is absent by default", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} = Dolphin.prepare_home(path: exe, iso_path: "/x.iso", home: home)
      refute read_ini(home) =~ "MonthlyFolders"
    end

    test "writes SlippiReplayMonthlyFolders under [Core] for ishiiruka", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/x.iso",
                 home: home,
                 replay_monthly_folders: true
               )

      assert read_ini(home) =~ "SlippiReplayMonthlyFolders = True"
    end

    test "writes ReplayMonthlyFolders under [Slippi] for mainline", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "netplay-beta")
      File.mkdir_p!(dir)
      exe = fake_exe(dir, "Slippi_Netplay_Mainline-x86_64.AppImage")
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/x.iso",
                 home: home,
                 replay_monthly_folders: false
               )

      ini = read_ini(home)
      assert ini =~ "ReplayMonthlyFolders = False"
      refute ini =~ "SlippiReplayMonthlyFolders"
    end
  end

  describe "log_types / Logger.ini" do
    test "no Logger.ini is written unless :log_types is given", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} = Dolphin.prepare_home(path: exe, iso_path: "/x.iso", home: home)
      refute File.exists?(logger_ini(home))
    end

    test "an explicit list enables exactly those types", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/x.iso",
                 home: home,
                 log_types: ["SLIPPI", "CORE"],
                 log_level: 5
               )

      ini = File.read!(logger_ini(home))
      assert ini =~ "WriteToFile = True"
      assert ini =~ "Verbosity = 5"
      assert ini =~ "SLIPPI = True"
      assert ini =~ "CORE = True"
      refute ini =~ "NETPLAY = True"
    end

    test "ALL enables every Dolphin log type", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, _} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/x.iso",
                 home: home,
                 log_types: ["ALL"]
               )

      ini = File.read!(logger_ini(home))
      assert ini =~ "Verbosity = 3"

      for type <- Dolphin.all_log_types() do
        assert ini =~ "#{type} = True", "missing log type #{type}"
      end
    end
  end

  describe "user.json (has_user_json)" do
    test "false when there is nothing to copy", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")

      assert {:ok, prep} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/x.iso",
                 home: home,
                 autodetect: false
               )

      refute prep.user_json?
      refute File.exists?(user_json(home))
      # the Slippi dir is still created, as upstream does
      assert File.dir?(Path.join(home, "Slippi"))
    end

    test "an explicit :user_json_path is copied in", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")
      src = Path.join(tmp, "mine.json")
      File.write!(src, ~s({"uid":"abc"}))

      assert {:ok, prep} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/x.iso",
                 home: home,
                 user_json_path: src,
                 autodetect: false
               )

      assert prep.user_json?
      assert File.read!(user_json(home)) == ~s({"uid":"abc"})
    end

    test "an existing user.json in the home is kept as-is", %{tmp_dir: tmp} do
      exe = fake_exe(tmp)
      home = Path.join(tmp, "home")
      File.mkdir_p!(Path.join(home, "Slippi"))
      File.write!(user_json(home), ~s({"uid":"already here"}))

      assert {:ok, prep} =
               Dolphin.prepare_home(
                 path: exe,
                 iso_path: "/x.iso",
                 home: home,
                 autodetect: false
               )

      assert prep.user_json?
      assert File.read!(user_json(home)) == ~s({"uid":"already here"})
    end

    test "setup_user_json/3 copies from a detected launcher home", %{tmp_dir: tmp} do
      launcher_home = Path.join(tmp, "launcher-home")
      File.mkdir_p!(Path.join(launcher_home, "Slippi"))
      File.write!(Path.join([launcher_home, "Slippi", "user.json"]), ~s({"uid":"launcher"}))

      info = %Melee.Dolphin.Info{
        install_dir: Path.join(tmp, "netplay"),
        mainline?: false,
        home_path: launcher_home,
        iso_path: nil,
        settings: %{}
      }

      home = Path.join(tmp, "home")
      assert Dolphin.setup_user_json(home, nil, info)
      assert File.read!(user_json(home)) == ~s({"uid":"launcher"})
    end

    test "setup_user_json/3 is false when the launcher home has none either", %{tmp_dir: tmp} do
      info = %Melee.Dolphin.Info{
        install_dir: Path.join(tmp, "netplay"),
        mainline?: false,
        home_path: Path.join(tmp, "empty-launcher-home"),
        iso_path: nil,
        settings: %{}
      }

      refute Dolphin.setup_user_json(Path.join(tmp, "home"), nil, info)
    end
  end

  describe "watch/2" do
    import ExUnit.CaptureLog

    # A stand-in for a launched Dolphin: a port on a short script, with
    # the same options start_process uses.
    defp fake_dolphin(script) do
      port =
        Port.open({:spawn_executable, ~c"/bin/sh"}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-c", script]
        ])

      %Dolphin{
        port: port,
        os_pid: 424_242,
        exe: "/bin/sh",
        home: "/nonexistent",
        slippi_port: 51_441,
        flavor: :ishiiruka,
        temp_home?: false
      }
    end

    test "a death is logged with status and output tail, and messaged" do
      dolphin = fake_dolphin("echo boom stdout; echo boom stderr >&2; exit 3")

      log =
        capture_log(fn ->
          Dolphin.watch(dolphin)
          assert_receive {:dolphin_exited, 424_242, 3}, 5_000
        end)

      assert log =~ "exited with status 3"
      assert log =~ "boom stdout"
      # :stderr_to_stdout captures stderr too — that's where crash
      # evidence like "A signal was received" lands.
      assert log =~ "boom stderr"
    end

    test "a clean exit is messaged with status 0" do
      dolphin = fake_dolphin("exit 0")

      capture_log(fn ->
        Dolphin.watch(dolphin)
        assert_receive {:dolphin_exited, 424_242, 0}, 5_000
      end)
    end

    test "an intentional port close (stop/1) is silent, and the watcher exits" do
      dolphin = fake_dolphin("sleep 30")
      watcher = Dolphin.watch(dolphin)

      # stop/1's first act; the script has no real Dolphin behind it,
      # so closing the port is the whole teardown here.
      Port.close(dolphin.port)

      refute_receive {:dolphin_exited, _, _}, 300
      refute Process.alive?(watcher)
    end
  end
end
