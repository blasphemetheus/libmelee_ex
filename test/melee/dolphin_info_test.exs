defmodule Melee.DolphinInfoTest do
  use ExUnit.Case, async: true

  alias Melee.Dolphin
  alias Melee.Dolphin.Info

  doctest Melee.Dolphin.Info

  @moduletag :tmp_dir

  # Build a fake Slippi Launcher directory: a Settings file plus whichever
  # install subdirectories are asked for.
  defp launcher(tmp, settings, install_dirs) do
    dir = Path.join(tmp, "Slippi Launcher")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Settings"), Jason.encode!(settings))
    for name <- install_dirs, do: File.mkdir_p!(Path.join(dir, name))
    dir
  end

  defp iso(tmp) do
    path = Path.join(tmp, "melee.iso")
    File.write!(path, "not really an iso")
    path
  end

  describe "detect/1 — flavor" do
    test "useNetplayBeta true selects the mainline install", %{tmp_dir: tmp} do
      dir = launcher(tmp, %{"settings" => %{"useNetplayBeta" => true}}, ["netplay-beta"])

      assert {:ok, %Info{mainline?: true, install_dir: install}} = Info.detect(dir)
      assert install == Path.join(dir, "netplay-beta")
    end

    test "useNetplayBeta false selects the Ishiiruka install", %{tmp_dir: tmp} do
      dir = launcher(tmp, %{"settings" => %{"useNetplayBeta" => false}}, ["netplay"])

      assert {:ok, %Info{mainline?: false, install_dir: install}} = Info.detect(dir)
      assert install == Path.join(dir, "netplay")
    end

    # The v0.43 → v0.47 fix: upstream raised KeyError here.
    test "a missing useNetplayBeta defaults to false instead of raising", %{tmp_dir: tmp} do
      dir = launcher(tmp, %{"settings" => %{}}, ["netplay"])
      assert {:ok, %Info{mainline?: false}} = Info.detect(dir)
    end

    test "a missing settings object also defaults to false", %{tmp_dir: tmp} do
      dir = launcher(tmp, %{"accounts" => %{}}, ["netplay"])
      assert {:ok, %Info{mainline?: false, settings: %{"accounts" => %{}}}} = Info.detect(dir)
    end
  end

  describe "detect/1 — ISO" do
    test "reports isoPath when the file exists", %{tmp_dir: tmp} do
      path = iso(tmp)
      dir = launcher(tmp, %{"settings" => %{"isoPath" => path}}, ["netplay"])

      assert {:ok, %Info{iso_path: ^path}} = Info.detect(dir)
    end

    test "nils out an isoPath that no longer exists", %{tmp_dir: tmp} do
      dir = launcher(tmp, %{"settings" => %{"isoPath" => "/nope/gone.iso"}}, ["netplay"])
      assert {:ok, %Info{iso_path: nil}} = Info.detect(dir)
    end

    test "a null isoPath is nil, not a crash", %{tmp_dir: tmp} do
      dir = launcher(tmp, %{"settings" => %{"isoPath" => nil}}, ["netplay"])
      assert {:ok, %Info{iso_path: nil}} = Info.detect(dir)
    end
  end

  describe "detect/1 — home path and errors" do
    test "derives the per-flavor default home path", %{tmp_dir: tmp} do
      dir = launcher(tmp, %{"settings" => %{"useNetplayBeta" => true}}, ["netplay-beta"])
      {:ok, info} = Info.detect(dir)

      assert info.home_path ==
               Info.default_home_path(true, System.user_home!())

      assert String.ends_with?(info.home_path, "slippi-dolphin/netplay-beta")
    end

    test "a launcher that isn't installed is an error, not a raise", %{tmp_dir: tmp} do
      missing = Path.join(tmp, "nothing here")
      assert {:error, {:launcher_settings_missing, _}} = Info.detect(missing)
    end

    test "malformed Settings JSON is an error", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "Slippi Launcher")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Settings"), "{not json")

      assert {:error, {:launcher_settings_unreadable, _, _}} = Info.detect(dir)
    end

    test "a settings file naming an install dir that isn't there", %{tmp_dir: tmp} do
      dir = launcher(tmp, %{"settings" => %{"useNetplayBeta" => true}}, [])
      assert {:error, {:install_dir_not_found, _}} = Info.detect(dir)
    end
  end

  describe "Dolphin.default_info/1 and default_install_path/1" do
    test "delegate to Info.detect/1", %{tmp_dir: tmp} do
      dir = launcher(tmp, %{"settings" => %{"useNetplayBeta" => true}}, ["netplay-beta"])

      assert {:ok, %Info{mainline?: true}} = Dolphin.default_info(launcher_path: dir)
      assert {:ok, install, true} = Dolphin.default_install_path(launcher_path: dir)
      assert install == Path.join(dir, "netplay-beta")
    end
  end

  describe "prepare_home/1 autodetection" do
    setup %{tmp_dir: tmp} do
      path = iso(tmp)

      dir =
        launcher(
          tmp,
          %{"settings" => %{"useNetplayBeta" => false, "isoPath" => path}},
          ["netplay"]
        )

      exe = Path.join([dir, "netplay", "Slippi_Online-x86_64.AppImage"])
      File.write!(exe, "#!/bin/sh\nsleep 30\n")
      File.chmod!(exe, 0o755)

      {:ok, launcher_dir: dir, exe: exe, iso: path}
    end

    test "fills in both path and iso_path", ctx do
      home = Path.join(ctx.tmp_dir, "home")

      assert {:ok, prep} = Dolphin.prepare_home(launcher_path: ctx.launcher_dir, home: home)
      assert prep.exe == ctx.exe
      assert prep.flavor == :ishiiruka
      assert ["-e", iso, "-u", ^home] = prep.args
      assert iso == ctx.iso
    end

    test "an explicit option still wins over detection", ctx do
      home = Path.join(ctx.tmp_dir, "home")

      assert {:ok, prep} =
               Dolphin.prepare_home(
                 launcher_path: ctx.launcher_dir,
                 iso_path: "/custom/melee.iso",
                 home: home
               )

      assert ["-e", "/custom/melee.iso", "-u", ^home] = prep.args
    end

    test "autodetect: false disables the fallback", ctx do
      assert {:error, {:missing_option, :path}} =
               Dolphin.prepare_home(launcher_path: ctx.launcher_dir, autodetect: false)
    end

    test "an uninstalled launcher gives a clear error, not a crash", ctx do
      assert {:error, {:missing_option, :path}} =
               Dolphin.prepare_home(launcher_path: Path.join(ctx.tmp_dir, "absent"))
    end
  end
end
