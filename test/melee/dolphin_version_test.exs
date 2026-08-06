defmodule Melee.DolphinVersionTest do
  use ExUnit.Case, async: true

  alias Melee.Dolphin
  alias Melee.Dolphin.Version

  doctest Melee.Dolphin.Version

  @moduletag :tmp_dir

  # A stand-in Dolphin: writes the given stdout/stderr and exits with the
  # given status, exactly as the real builds do for `--version`.
  defp fake_dolphin(dir, name, status, stdout, stderr) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    printf '%s' '#{stdout}'
    printf '%s' '#{stderr}' >&2
    exit #{status}
    """)

    File.chmod!(path, 0o755)
    path
  end

  describe "classify/3" do
    test "the ExiAI marker is what separates the two mainline builds" do
      assert {:ok, %Version{build: :netplay}} = Version.classify(0, "4.0.0-mainline-beta.19", "")
      assert {:ok, %Version{build: :exi_ai}} = Version.classify(0, "4.0.0-mainline-ExiAI.1", "")
    end

    test "an ExiAI Ishiiruka banner that isn't ExiAI is rejected" do
      assert {:error, {:unexpected_version_output, _}} =
               Version.classify(1, "", "Faster Melee - Slippi (3.5.1) - Something")
    end

    test "an unknown exit status is an error" do
      assert {:error, {:unexpected_exit_status, 42, "out", "err"}} =
               Version.classify(42, "out\n", "err\n")
    end
  end

  describe "version/1" do
    test "mainline netplay", %{tmp_dir: tmp} do
      exe = fake_dolphin(tmp, "dolphin-mainline", 0, "4.0.0-mainline-beta.19\n", "")

      assert {:ok, %Version{mainline?: true, build: :netplay, version: "4.0.0-mainline-beta.19"}} =
               Dolphin.version(exe)
    end

    test "mainline ExiAI", %{tmp_dir: tmp} do
      exe = fake_dolphin(tmp, "dolphin-exiai-mainline", 0, "4.0.0-mainline-ExiAI.2\n", "")
      assert {:ok, %Version{mainline?: true, build: :exi_ai}} = Dolphin.version(exe)
    end

    # Loader noise on stderr must not corrupt the stdout version — this is
    # why the probe captures the two streams separately.
    test "Ishiiruka netplay, with unrelated stderr noise", %{tmp_dir: tmp} do
      exe =
        fake_dolphin(tmp, "dolphin-netplay", 255, "3.6.4\n", "libgvfscommon.so: undefined symbol")

      assert {:ok, %Version{mainline?: false, build: :netplay, version: "3.6.4"}} =
               Dolphin.version(exe)
    end

    test "ExiAI Ishiiruka reports on stderr with status 1", %{tmp_dir: tmp} do
      exe = fake_dolphin(tmp, "dolphin-exiai", 1, "", "Faster Melee - Slippi (3.5.1) - ExiAI")

      assert {:ok, %Version{mainline?: false, build: :exi_ai, version: "3.5.1"}} =
               Dolphin.version(exe)
    end

    test "an unresolvable path errors", %{tmp_dir: tmp} do
      assert {:error, {:invalid_dolphin_path, _}} = Dolphin.version(Path.join(tmp, "nope"))
    end
  end

  describe "against the real builds" do
    @tag :dolphin
    test "netplay-stable and ExiAI are told apart" do
      launcher = Path.join([System.user_home!(), ".config", "Slippi Launcher"])
      netplay = Path.join([launcher, "netplay", "Slippi_Online-x86_64.AppImage"])
      exiai = Path.join([System.user_home!(), ".local/share/slippi/exi-ai/dolphin-emu-headless"])

      assert {:ok, %Version{mainline?: false, build: :netplay}} = Dolphin.version(netplay)
      assert {:ok, %Version{mainline?: false, build: :exi_ai}} = Dolphin.version(exiai)
    end
  end
end
