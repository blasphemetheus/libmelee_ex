defmodule Melee.Dolphin.Info do
  @moduledoc """
  Slippi Launcher autodetection: where the launcher keeps its settings,
  which Dolphin install it is currently configured to use, and which ISO.

  Ports libmelee v0.47's `DolphinInfo`, `slippi_launcher_path`,
  `default_dolphin_info` and `default_dolphin_install_path`
  (`console.py`).

  ## Linux only

  Upstream supports Windows (`%APPDATA%/Slippi Launcher`) and macOS
  (`~/Library/Application Support/Slippi Launcher`) as well. This port is
  Linux-only throughout (the ENet NIF, the named-pipe controller
  protocol and the AppImage executable names all assume it), so
  `launcher_path/0` answers `{:error, {:unsupported_os, os}}` anywhere
  else rather than guessing.

  ## What is read

  `<launcher>/Settings` is JSON. Two keys under `"settings"` matter:

    * `"useNetplayBeta"` — true means the mainline build. Read with a
      **default of `false`**: v0.43 raised `KeyError` when the key was
      absent, which the fork fixed, and plenty of real launcher configs
      predate the key.
    * `"isoPath"` — nulled out when the file it names does not exist, so
      a stale path never reaches Dolphin's command line.

  The install directory is `<launcher>/netplay-beta` for mainline and
  `<launcher>/netplay` otherwise; the default Dolphin *home* (user)
  directory is a separate, fixed per-flavor location.
  """

  @enforce_keys [:install_dir, :mainline?, :home_path, :iso_path, :settings]
  defstruct [:install_dir, :mainline?, :home_path, :iso_path, :settings]

  @typedoc """
  A detected Slippi Launcher / Dolphin installation.

    * `:install_dir` — directory holding the Dolphin executable
    * `:mainline?` — true for the mainline (netplay-beta) build
    * `:home_path` — the build's default Dolphin user directory
    * `:iso_path` — the launcher's configured ISO, or `nil` when unset
      or missing on disk
    * `:settings` — the whole decoded `Settings` document
  """
  @type t :: %__MODULE__{
          install_dir: Path.t(),
          mainline?: boolean(),
          home_path: Path.t(),
          iso_path: Path.t() | nil,
          settings: map()
        }

  @type error ::
          {:unsupported_os, atom()}
          | {:launcher_settings_missing, Path.t()}
          | {:launcher_settings_unreadable, Path.t(), term()}
          | {:install_dir_not_found, Path.t()}

  @doc """
  Directory the Slippi Launcher keeps its `Settings` file in.

  Linux only — see the module doc.

      iex> match?({:ok, _}, Melee.Dolphin.Info.launcher_path())
      true
  """
  @spec launcher_path() :: {:ok, Path.t()} | {:error, error()}
  def launcher_path do
    case :os.type() do
      {:unix, :linux} -> {:ok, Path.join([System.user_home!(), ".config", "Slippi Launcher"])}
      {_family, name} -> {:error, {:unsupported_os, name}}
    end
  end

  @doc """
  Name of the install subdirectory the launcher uses for a flavor.

  ## Examples

      iex> Melee.Dolphin.Info.install_dir_name(true)
      "netplay-beta"

      iex> Melee.Dolphin.Info.install_dir_name(false)
      "netplay"
  """
  @spec install_dir_name(boolean()) :: String.t()
  def install_dir_name(true), do: "netplay-beta"
  def install_dir_name(false), do: "netplay"

  @doc """
  Default Dolphin user (home) directory for a flavor on Linux, matching
  console.py's `_default_home_path`.

  ## Examples

      iex> Melee.Dolphin.Info.default_home_path(true, "/home/me")
      "/home/me/.config/slippi-dolphin/netplay-beta"

      iex> Melee.Dolphin.Info.default_home_path(false, "/home/me")
      "/home/me/.config/SlippiOnline"
  """
  @spec default_home_path(boolean(), Path.t()) :: Path.t()
  def default_home_path(true, home),
    do: Path.join([home, ".config", "slippi-dolphin", "netplay-beta"])

  def default_home_path(false, home), do: Path.join([home, ".config", "SlippiOnline"])

  @doc """
  Detect the Dolphin install the Slippi Launcher is configured to use.

  Pass `launcher` to point at a launcher directory other than
  `launcher_path/0` (tests do this). Never raises: a missing or
  malformed `Settings`, or a missing install directory, comes back as
  `{:error, reason}`.
  """
  @spec detect(Path.t() | nil) :: {:ok, t()} | {:error, error()}
  def detect(launcher \\ nil)

  def detect(nil) do
    with {:ok, launcher} <- launcher_path(), do: detect(launcher)
  end

  def detect(launcher) do
    with {:ok, settings} <- read_settings(launcher) do
      mainline? = get_setting(settings, "useNetplayBeta", false) == true
      install_dir = Path.join(launcher, install_dir_name(mainline?))

      if File.dir?(install_dir) do
        {:ok,
         %__MODULE__{
           install_dir: install_dir,
           mainline?: mainline?,
           home_path: default_home_path(mainline?, System.user_home!()),
           iso_path: existing_iso(get_setting(settings, "isoPath", nil)),
           settings: settings
         }}
      else
        {:error, {:install_dir_not_found, install_dir}}
      end
    end
  end

  ## ------------------------------------------------------------------
  ## Internals
  ## ------------------------------------------------------------------

  defp read_settings(launcher) do
    path = Path.join(launcher, "Settings")

    case File.read(path) do
      {:ok, body} -> decode_settings(path, body)
      {:error, :enoent} -> {:error, {:launcher_settings_missing, path}}
      {:error, reason} -> {:error, {:launcher_settings_unreadable, path, reason}}
    end
  end

  defp decode_settings(path, body) do
    case Jason.decode(body) do
      {:ok, settings} when is_map(settings) -> {:ok, settings}
      {:ok, other} -> {:error, {:launcher_settings_unreadable, path, {:not_an_object, other}}}
      {:error, reason} -> {:error, {:launcher_settings_unreadable, path, reason}}
    end
  end

  # Tolerant read of `settings.<key>`: a missing "settings" object, or a
  # missing key inside it, yields the default rather than an error.
  defp get_setting(settings, key, default) do
    case Map.get(settings, "settings") do
      inner when is_map(inner) -> Map.get(inner, key, default) || default
      _ -> default
    end
  end

  defp existing_iso(nil), do: nil

  defp existing_iso(path) when is_binary(path) do
    if File.regular?(path), do: path, else: nil
  end

  defp existing_iso(_other), do: nil
end
