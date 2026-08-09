defmodule Melee.Dolphin do
  @moduledoc """
  Dolphin process management: user-directory setup, config rendering, launch
  and shutdown of a Slippi Dolphin instance.

  Ports the Dolphin-management slice of libmelee's `Console` (`console.py`):
  exe-path resolution, mainline/Ishiiruka flavor detection, `Dolphin.ini` /
  gecko-code setup (`_setup_dolphin_ini`, `_setup_gecko_codes`), and
  `run`/`stop`. Config keys mirror console.py exactly:

    * Ishiiruka/ExiAI writes spectator keys under `[Core]`
      (`SlippiEnableSpectator`, `SlippiSpectatorLocalPort`, ...).
    * Mainline writes them under `[Slippi]`
      (`EnableSpectator`, `SpectatorLocalPort`, ...) and additionally accepts
      `--platform headless` on the command line.

  ## Slippi Launcher autodetection

  `launch/1`/`prepare_home/1` consult the Slippi Launcher's `Settings`
  file (see `Melee.Dolphin.Info`) when `:path`, `:iso_path` or
  `:user_json_path` are not given, so on a machine with the launcher
  installed `launch([])` is enough. Detection failures are never fatal:
  they only mean `:path`/`:iso_path` go back to being required, and a
  warning names the one that is missing. `autodetect: false` skips the
  lookup entirely.

  ## Process ownership

  `launch/1` opens the Dolphin process as an Erlang `Port` owned by the
  *calling* process. The caller therefore receives the port's messages —
  in particular `{port, {:exit_status, n}}` when Dolphin exits, and any
  `{port, {:data, bin}}` stdout output. If the calling process dies, the
  port closes and Dolphin's stdin is closed (though Dolphin may linger;
  use `stop/1` for a guaranteed kill).

  ## Memory cards

  `:memory_card` decides what is in the GameCube's card slots:

    * `false` (default) — both slots empty. A bot needs no save data,
      and an empty slot skips Melee's boot dialogs entirely.
    * `true` — leave the slots as the copied/base config has them.
      Note this only *preserves* config; it does not plug a card in, so
      a home configured with `SlotA = 255` still boots without one and
      nothing the game saves will persist.
    * `:folder` — provision a GCI-folder card in slot A (creating
      `gci_folder_path/2`) and select it. Use this when the game must
      remember something between runs, such as an in-game nametag. On
      the first boot with a fresh folder Melee asks to create game data;
      `Melee.MenuHelper` answers that prompt by default.

  ## Controller setup ordering

  `setup_controller/3` (and any other config written into the home
  directory) MUST be called *before* `launch/1`'s Dolphin process actually
  reads its config — i.e. call `prepare_home/1`, then `setup_controller/3`
  on the prepared home, then start the process. The convenience path is:
  build the home yourself via `prepare_home/1`, wire controllers, then
  `launch(home: home, ...)` — or simply call `setup_controller/3` on a
  launched struct only when you accept that Dolphin must be restarted to
  pick it up.

  `:controller_ports` accepts bare port numbers (wired as `:standard`
  pipe controllers) or `{port, type}` tuples — declare
  `{2, :gcn_adapter}` for a local human-vs-bot session. All four ports
  are written explicitly (undeclared ports become `:unplugged` via
  `DolphinConfig.declare_ports/2`), so a session that declares no
  adapter port never claims the GC adapter's USB device.
  """

  alias Melee.Dolphin.Info
  alias Melee.Dolphin.Version
  alias Melee.DolphinConfig

  require Logger

  @enforce_keys [:exe, :home, :slippi_port, :flavor, :temp_home?]
  defstruct [
    :port,
    :os_pid,
    :exe,
    :home,
    :slippi_port,
    :flavor,
    :temp_home?,
    user_json?: false
  ]

  @typedoc """
  A running (or launched-then-stopped) Dolphin instance.

    * `:port` — the Erlang `Port` (nil after `stop/1`)
    * `:os_pid` — OS pid of the Dolphin process
    * `:exe` — resolved executable path
    * `:home` — Dolphin user directory in use
    * `:slippi_port` — spectator UDP port Slippi listens on
    * `:flavor` — `:ishiiruka` or `:mainline`
    * `:temp_home?` — whether we created `:home` and delete it on `stop/1`
    * `:user_json?` — whether `<home>/Slippi/user.json` ended up in place
      (netplay/connect-code play needs it; see `setup_user_json/2`)
  """
  @type t :: %__MODULE__{
          port: port() | nil,
          os_pid: pos_integer() | nil,
          exe: Path.t(),
          home: Path.t(),
          slippi_port: pos_integer(),
          flavor: :ishiiruka | :mainline,
          temp_home?: boolean(),
          user_json?: boolean()
        }

  @type flavor :: :ishiiruka | :mainline
  @type launch_opt ::
          {:path, Path.t()}
          | {:iso_path, Path.t()}
          | {:autodetect, boolean()}
          | {:launcher_path, Path.t()}
          | {:user_json_path, Path.t()}
          | {:replay_monthly_folders, boolean()}
          | {:log_types, [String.t()]}
          | {:log_level, 1..5}
          | {:home, Path.t()}
          | {:copy_home_from, Path.t()}
          | {:slippi_port, pos_integer()}
          | {:flavor, flavor() | :auto}
          | {:headless, boolean()}
          | {:gfx_backend, String.t()}
          | {:emulation_speed, number()}
          | {:memory_card, boolean() | :folder}
          | {:memory_card_region, String.t()}
          | {:blocking_input, boolean()}
          | {:online_delay, non_neg_integer()}
          | {:save_replays, boolean()}
          | {:replay_dir, Path.t()}
          | {:setup_gecko_codes, boolean()}
          | {:gecko_extra_codes, [String.t()]}
          | {:extra_args, [String.t()]}

  @default_slippi_port 51_441

  # Every Dolphin log-type short name (console.py's ALL_LOG_TYPES, taken
  # from the first string of each m_log entry in
  # Source/Core/Common/Logging/LogManager.cpp). Order and spelling are
  # upstream's, including the two names with spaces.
  @all_log_types [
    "Achievements",
    "ActionReplay",
    "Audio",
    "AI",
    "BOOT",
    "CP",
    "COMMON",
    "CONSOLE",
    "CI",
    "CORE",
    "DIO",
    "DSPHLE",
    "DSPLLE",
    "DSPMails",
    "DSP",
    "DVD",
    "JIT",
    "EXI",
    "FileMon",
    "FRAMEDUMP",
    "GDB_STUB",
    "GP",
    "Host GPU",
    "HSP",
    "IOS",
    "IOS_DI",
    "IOS_ES",
    "IOS_FS",
    "IOS_SD",
    "IOS_SSL",
    "IOS_STM",
    "IOS_NET",
    "IOS_USB",
    "IOS_WC24",
    "IOS_WFS",
    "IOS_WIIMOTE",
    "MASTER",
    "MemCard Manager",
    "MI",
    "NETPLAY",
    "HLE",
    "OSREPORT",
    "OSREPORT_HLE",
    "PE",
    "PI",
    "PowerPC",
    "SI",
    "SLIPPI",
    "SLIPPI_ONLINE",
    "SLIPPI_RUST_DEPENDENCIES",
    "SLIPPI_RUST_ONLINE",
    "SLIPPI_RUST_JUKEBOX",
    "SP1",
    "SYMBOLS",
    "Video",
    "VI",
    "Wiimote",
    "WII_IPC"
  ]

  # Linux executable names inside a Slippi Launcher install dir
  # (console.py get_exe_path).
  @ishiiruka_exe "Slippi_Online-x86_64.AppImage"
  @mainline_exe "Slippi_Netplay_Mainline-x86_64.AppImage"

  ## ------------------------------------------------------------------
  ## Launch / lifecycle
  ## ------------------------------------------------------------------

  @doc """
  Set up a Dolphin user directory and start the Dolphin process.

  See the module doc for option semantics. `:path` and `:iso_path` are
  required only when they cannot be autodetected from the Slippi
  Launcher (see `default_info/1`); pass `autodetect: false` to skip
  detection entirely. Returns `{:ok, t}` with the Port owned by the
  caller (the caller receives `{port, {:exit_status, n}}` when Dolphin
  exits).
  """
  @spec launch([launch_opt()]) :: {:ok, t()} | {:error, term()}
  def launch(opts) do
    with {:ok, prep} <- prepare_home(opts) do
      start_process(prep)
    end
  end

  @doc """
  Pure setup step used by `launch/1`: resolve the executable, create and
  configure the user directory, and compute the command-line arguments —
  without starting any process.

  Returns `{:ok, prep}` where `prep` is a map with `:exe`, `:home`,
  `:flavor`, `:temp_home?`, `:slippi_port`, `:user_json?`, `:info` (the
  autodetected `Melee.Dolphin.Info`, or `nil`) and `:args` (full argv
  after the executable). Useful for tests and for wiring controllers
  into the home before launching.
  """
  @spec prepare_home([launch_opt()]) ::
          {:ok,
           %{
             exe: Path.t(),
             home: Path.t(),
             flavor: flavor(),
             temp_home?: boolean(),
             slippi_port: pos_integer(),
             user_json?: boolean(),
             info: Info.t() | nil,
             args: [String.t()]
           }}
          | {:error, term()}
  def prepare_home(opts) do
    info = detect_info(opts)

    with {:ok, path} <- resolve_path_opt(opts, :path, info && info.install_dir),
         {:ok, iso_path} <- resolve_path_opt(opts, :iso_path, info && info.iso_path),
         {:ok, exe, flavor} <- resolve_exe(path, Keyword.get(opts, :flavor, :auto)),
         {:ok, home, temp_home?} <- setup_home_dir(opts) do
      headless = Keyword.get(opts, :headless, false)
      slippi_port = Keyword.get(opts, :slippi_port, @default_slippi_port)

      write_dolphin_ini(home, flavor, slippi_port, headless, opts)
      write_logger_ini(home, opts)
      user_json? = setup_user_json(home, Keyword.get(opts, :user_json_path), info)

      if Keyword.get(opts, :setup_gecko_codes, true) do
        write_gecko_codes(home, Keyword.get(opts, :gecko_extra_codes, []))
      end

      # Bot controllers must be wired in BEFORE the process starts —
      # Dolphin reads pad config at boot. declare_ports/2 also UNPLUGS
      # every port not listed, so an adapter claim inherited from the
      # home template (libmelee leaves ports 3/4 on SIDevice 12) can't
      # ride along and grab the human's GC adapter. A local showcase
      # that wants the adapter declares it: `{2, :gcn_adapter}`.
      ports_spec =
        opts
        |> Keyword.get(:controller_ports, [])
        |> Map.new(fn
          {port, type} -> {port, type}
          port when is_integer(port) -> {port, :standard}
        end)

      {:ok, _pipes} = DolphinConfig.declare_ports(home, ports_spec)

      platform_args =
        if flavor == :mainline and headless, do: ["--platform", "headless"], else: []

      args =
        ["-e", iso_path, "-u", home] ++ platform_args ++ Keyword.get(opts, :extra_args, [])

      {:ok,
       %{
         exe: exe,
         home: home,
         flavor: flavor,
         temp_home?: temp_home?,
         slippi_port: slippi_port,
         user_json?: user_json?,
         info: info,
         args: args
       }}
    end
  end

  ## ------------------------------------------------------------------
  ## Slippi Launcher autodetection (console.py default_dolphin_info)
  ## ------------------------------------------------------------------

  @doc """
  Detect the Dolphin install the Slippi Launcher is configured to use.

  Delegates to `Melee.Dolphin.Info.detect/1`; pass `:launcher_path` to
  read a launcher directory other than the OS default. Returns
  `{:error, reason}` — never raises — when the launcher is not
  installed, so callers that supply `:path`/`:iso_path` themselves are
  unaffected by its absence.
  """
  @spec default_info([{:launcher_path, Path.t()}]) :: {:ok, Info.t()} | {:error, term()}
  def default_info(opts \\ []) do
    Info.detect(Keyword.get(opts, :launcher_path))
  end

  @doc """
  The autodetected install directory and whether it is mainline —
  console.py's backwards-compatibility `default_dolphin_install_path`.
  """
  @spec default_install_path([{:launcher_path, Path.t()}]) ::
          {:ok, Path.t(), boolean()} | {:error, term()}
  def default_install_path(opts \\ []) do
    with {:ok, info} <- default_info(opts), do: {:ok, info.install_dir, info.mainline?}
  end

  # Detection is IO, so only do it when something is actually missing.
  # Upstream ties `dolphin_info` to `path is None` alone; we also detect
  # for a missing `:iso_path`, but deliberately NOT for a missing
  # `:user_json_path` — otherwise a fully-specified launch would start
  # pulling the machine's launcher identity into its home.
  defp detect_info(opts) do
    needed? =
      Keyword.get(opts, :autodetect, true) and
        (is_nil(Keyword.get(opts, :path)) or is_nil(Keyword.get(opts, :iso_path)))

    if needed? do
      case default_info(opts) do
        {:ok, info} ->
          info

        {:error, reason} ->
          Logger.debug("Slippi Launcher autodetection unavailable: #{inspect(reason)}")
          nil
      end
    end
  end

  # An explicit option always wins; otherwise fall back to what the
  # launcher told us. Keeps the historical `{:missing_option, key}` error
  # when neither is available, and warns first so the cause is visible.
  defp resolve_path_opt(opts, key, detected) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        {:ok, value}

      nil when is_binary(detected) ->
        {:ok, detected}

      nil ->
        Logger.warning(
          "Melee.Dolphin: no #{key} given and none could be autodetected " <>
            "from the Slippi Launcher"
        )

        {:error, {:missing_option, key}}

      value ->
        {:error, {:invalid_option, key, value}}
    end
  end

  @doc """
  Wire a bot controller into this instance's user directory (fifo +
  `GCPadNew.ini` + `SIDevice`). Delegates to `Melee.DolphinConfig`.

  NOTE: Dolphin reads controller config at startup — call this before
  `launch/1` (via `prepare_home/1` + `:home`) for it to take effect;
  calling it on an already-running instance requires a restart.
  """
  @spec setup_controller(t(), DolphinConfig.gc_port(), :standard | :gcn_adapter | :unplugged) ::
          {:ok, Path.t()} | {:error, term()}
  def setup_controller(%__MODULE__{home: home}, port, type \\ :standard) do
    DolphinConfig.setup_controller(home, port, type)
  end

  @doc "The named-pipe path for a controller port under this instance's home."
  @spec pipes_path(t(), DolphinConfig.gc_port()) :: Path.t()
  def pipes_path(%__MODULE__{home: home}, port), do: DolphinConfig.pipes_path(home, port)

  @doc "Whether the Dolphin OS process is still running."
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{os_pid: nil}), do: false

  def alive?(%__MODULE__{os_pid: os_pid}) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end

  @doc """
  Stop the Dolphin process and clean up.

  Closes the Port, sends SIGTERM, and — because Dolphin often ignores
  polite signals — SIGKILLs the OS pid if it is still alive after ~2s.
  Deletes the home directory if we created it (`temp_home?: true`).
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = dolphin) do
    if dolphin.port && Port.info(dolphin.port), do: Port.close(dolphin.port)

    if dolphin.os_pid do
      pid_str = Integer.to_string(dolphin.os_pid)
      System.cmd("kill", [pid_str], stderr_to_stdout: true)

      unless wait_for_exit(dolphin, 2_000) do
        System.cmd("kill", ["-9", pid_str], stderr_to_stdout: true)
        wait_for_exit(dolphin, 1_000)
      end
    end

    if dolphin.temp_home?, do: File.rm_rf(dolphin.home)
    :ok
  end

  ## ------------------------------------------------------------------
  ## Exe resolution / flavor detection
  ## ------------------------------------------------------------------

  @doc """
  Resolve a Dolphin executable from a file path or install directory and
  determine its flavor.

  A direct file path is accepted as-is. A directory is resolved per
  console.py's `get_exe_path` rules (Linux Slippi Launcher AppImage names).
  `flavor: :auto` detects like console.py's `_is_mainline` — a path
  containing `netplay-beta` (or `mainline`) is mainline — falling back to
  `:ishiiruka` when the heuristic is inconclusive.
  """
  @spec resolve_exe(Path.t(), flavor() | :auto) ::
          {:ok, Path.t(), flavor()} | {:error, term()}
  def resolve_exe(path, flavor \\ :auto) do
    cond do
      File.regular?(path) ->
        {:ok, path, concrete_flavor(path, flavor)}

      File.dir?(path) ->
        resolved_flavor = concrete_flavor(path, flavor)

        exe_name = if resolved_flavor == :mainline, do: @mainline_exe, else: @ishiiruka_exe
        exe_path = Path.join(path, exe_name)

        if File.regular?(exe_path) do
          {:ok, exe_path, resolved_flavor}
        else
          {:error, {:exe_not_found, exe_path}}
        end

      true ->
        {:error, {:invalid_dolphin_path, path}}
    end
  end

  @doc """
  Heuristic flavor detection from a path (console.py `_is_mainline`):
  `netplay-beta` or `mainline` anywhere in the path means `:mainline`;
  anything else falls back to `:ishiiruka`.
  """
  @spec detect_flavor(Path.t()) :: flavor()
  def detect_flavor(path) do
    down = String.downcase(path)

    if String.contains?(down, "netplay-beta") or String.contains?(down, "mainline") do
      :mainline
    else
      :ishiiruka
    end
  end

  defp concrete_flavor(path, :auto), do: detect_flavor(path)
  defp concrete_flavor(_path, flavor) when flavor in [:ishiiruka, :mainline], do: flavor

  @doc """
  Run `<exe> --version` and report what build this Dolphin is.

  Accepts an executable path or an install directory (resolved with
  `resolve_exe/2`). Returns a `Melee.Dolphin.Version` carrying
  `:version`, `:build` (`:netplay` | `:playback` | `:exi_ai`) and
  `:mainline?` — see that module for how the three Linux builds are told
  apart. Unlike `detect_flavor/1` this asks the binary itself, so it is
  authoritative but costs a process spawn.
  """
  @spec version(Path.t()) :: {:ok, Version.t()} | {:error, term()}
  def version(path) do
    with {:ok, exe, _flavor} <- resolve_exe(path, :auto) do
      {status, stdout, stderr} = run_version(exe)
      Version.classify(status, stdout, stderr)
    end
  end

  # System.cmd can only merge stderr into stdout, and the two builds put
  # their version on *different* streams (with unrelated loader noise on
  # stderr), so capture them separately via a temp file.
  defp run_version(exe) do
    err_path =
      Path.join(System.tmp_dir!(), "melee_dolphin_version_#{System.unique_integer([:positive])}")

    try do
      {stdout, status} =
        System.cmd("sh", ["-c", ~s(exec "$0" --version 2>"$1"), exe, err_path],
          stderr_to_stdout: false
        )

      {status, stdout, err_path |> File.read() |> elem_or("")}
    after
      File.rm(err_path)
    end
  end

  defp elem_or({:ok, value}, _default), do: value
  defp elem_or(_error, default), do: default

  ## ------------------------------------------------------------------
  ## user.json (console.py _setup_home_directory)
  ## ------------------------------------------------------------------

  @doc """
  Put a `user.json` into `<home>/Slippi` if one can be found, and say
  whether the home ended up with one.

  Ports the `has_user_json` block of console.py's
  `_setup_home_directory`, in priority order:

    1. `user_json_path` is given — copy it in (overwriting).
    2. `<home>/Slippi/user.json` already exists — keep it.
    3. an autodetected launcher install has one in its own home — copy
       that in.
    4. otherwise `false`.

  Dolphin needs this file to know who you are; without it netplay and
  connect codes are not available, which is why `Melee.MenuHelper`
  accepts a `:user_json?` flag (see `step/4`).
  """
  @spec setup_user_json(Path.t(), Path.t() | nil, Info.t() | nil) :: boolean()
  def setup_user_json(home, user_json_path, info) do
    slippi_dir = Path.join(home, "Slippi")
    File.mkdir_p!(slippi_dir)
    dest = Path.join(slippi_dir, "user.json")

    cond do
      is_binary(user_json_path) -> copy_user_json(user_json_path, dest)
      File.exists?(dest) -> true
      is_nil(info) -> false
      true -> copy_user_json(Path.join([info.home_path, "Slippi", "user.json"]), dest)
    end
  end

  defp copy_user_json(src, dest) do
    if File.regular?(src) do
      File.cp(src, dest) == :ok
    else
      false
    end
  end

  ## ------------------------------------------------------------------
  ## Logger.ini (console.py _setup_dolphin_ini, logger section)
  ## ------------------------------------------------------------------

  @doc """
  Every Dolphin log-type short name, from
  `Source/Core/Common/Logging/LogManager.cpp` — the list upstream's
  `log_types: ['ALL']` expands to.

  ## Examples

      iex> length(Melee.Dolphin.all_log_types())
      58

      iex> "SLIPPI" in Melee.Dolphin.all_log_types()
      true
  """
  @spec all_log_types() :: [String.t()]
  def all_log_types, do: @all_log_types

  @doc """
  Expand a `:log_types` list, turning the `"ALL"` wildcard into
  `all_log_types/0`.

  ## Examples

      iex> Melee.Dolphin.expand_log_types(["SLIPPI", "CORE"])
      ["SLIPPI", "CORE"]

      iex> Melee.Dolphin.expand_log_types(["ALL"]) == Melee.Dolphin.all_log_types()
      true
  """
  @spec expand_log_types([String.t()]) :: [String.t()]
  def expand_log_types(log_types) do
    if "ALL" in log_types, do: @all_log_types, else: log_types
  end

  # Upstream always writes Logger.ini (defaulting to ['SLIPPI']); this
  # port writes it only when `:log_types` is given, so that existing
  # callers' homes are byte-for-byte unchanged.
  defp write_logger_ini(home, opts) do
    case Keyword.get(opts, :log_types) do
      nil ->
        :ok

      log_types when is_list(log_types) ->
        path = Path.join([home, "Config", "Logger.ini"])
        level = Keyword.get(opts, :log_level, 3)

        update_ini(path, "Options", [
          {"WriteToFile", "True"},
          {"Verbosity", to_string(level)}
        ])

        update_ini(path, "Logs", Enum.map(expand_log_types(log_types), &{&1, "True"}))
        :ok

      other ->
        raise ArgumentError, ":log_types must be a list of strings, got: #{inspect(other)}"
    end
  end

  ## ------------------------------------------------------------------
  ## Home directory setup
  ## ------------------------------------------------------------------

  defp setup_home_dir(opts) do
    {home, temp_home?} =
      case Keyword.get(opts, :home) do
        nil ->
          {Path.join(
             System.tmp_dir!(),
             "libmelee_#{System.unique_integer([:positive])}_#{:os.getpid()}"
           ), true}

        home ->
          {Path.expand(home), false}
      end

    File.mkdir_p!(home)

    case Keyword.get(opts, :copy_home_from) do
      nil -> {:ok, home, temp_home?}
      src -> copy_home(Path.expand(src), home, temp_home?)
    end
  end

  # Copy an existing Dolphin user dir into `dst`, skipping fifos
  # (console.py `_ignore_fifos` / `_copytree_safe`). Fifos report type
  # `:other` in File.stat on POSIX systems.
  defp copy_home(src, dst, temp_home?) do
    if File.dir?(src) do
      copy_tree(src, dst)
      {:ok, dst, temp_home?}
    else
      {:error, {:copy_home_from_not_a_directory, src}}
    end
  end

  defp copy_tree(src, dst) do
    File.mkdir_p!(dst)

    for name <- File.ls!(src) do
      src_path = Path.join(src, name)
      dst_path = Path.join(dst, name)

      case File.stat!(src_path) do
        %File.Stat{type: :directory} -> copy_tree(src_path, dst_path)
        %File.Stat{type: :regular} -> File.cp!(src_path, dst_path)
        # :other covers fifos/sockets/devices — skip, like _ignore_fifos
        _ -> :ok
      end
    end

    :ok
  end

  ## ------------------------------------------------------------------
  ## Dolphin.ini rendering (console.py _setup_dolphin_ini)
  ## ------------------------------------------------------------------

  defp write_dolphin_ini(home, flavor, slippi_port, headless, opts) do
    ini_path = Path.join([home, "Config", "Dolphin.ini"])

    online_delay = Keyword.get(opts, :online_delay, 0)
    blocking_input = Keyword.get(opts, :blocking_input, headless)
    emulation_speed = Keyword.get(opts, :emulation_speed, 1.0)
    gfx_backend = Keyword.get(opts, :gfx_backend, if(headless, do: "Null", else: ""))

    replay_dir =
      case Keyword.get(opts, :replay_dir) do
        nil ->
          nil

        dir ->
          dir = Path.expand(dir)
          File.mkdir_p!(dir)
          dir
      end

    # Invariant: a caller who configures a replay dir wants replays.
    # SaveReplays previously stayed False unless separately enabled, so a
    # session could point at a dir and still write NOTHING — every run
    # then reports "no fresh replay" with no hint why (the 2026-08-07
    # native-bridge regression: eval protocols scored stale files).
    # :save_replays therefore defaults to `replay_dir != nil`; an
    # explicit `save_replays: false` still wins.
    save_replays = Keyword.get(opts, :save_replays, replay_dir != nil)

    monthly = Keyword.get(opts, :replay_monthly_folders)

    slippi_entries =
      case flavor do
        :mainline ->
          {"Slippi",
           [
             {"EnableSpectator", "True"},
             {"SpectatorLocalPort", to_string(slippi_port)},
             {"OnlineDelay", to_string(online_delay)},
             {"BlockingPipes", bool_str(blocking_input)},
             {"SaveReplays", bool_str(save_replays)}
           ] ++
             if(replay_dir, do: [{"ReplayDir", replay_dir}], else: []) ++
             if(is_nil(monthly),
               do: [],
               else: [{"ReplayMonthlyFolders", bool_str(monthly)}]
             )}

        :ishiiruka ->
          {"Core",
           [
             {"SlippiEnableSpectator", "True"},
             {"SlippiSpectatorLocalPort", to_string(slippi_port)},
             {"SlippiOnlineDelay", to_string(online_delay)},
             {"BlockingPipes", bool_str(blocking_input)},
             {"SlippiSaveReplays", bool_str(save_replays)}
           ] ++
             if(replay_dir, do: [{"SlippiReplayDir", replay_dir}], else: []) ++
             if(is_nil(monthly),
               do: [],
               else: [{"SlippiReplayMonthlyFolders", bool_str(monthly)}]
             )}
      end

    {slippi_section, slippi_kvs} = slippi_entries
    update_ini(ini_path, slippi_section, slippi_kvs)
    update_ini(ini_path, "Input", [{"backgroundinput", "True"}])

    memory_card_kvs = memory_card_kvs(home, opts)

    core_kvs =
      [
        {"GFXBackend", gfx_backend},
        {"EmulationSpeed", to_string(emulation_speed)}
      ] ++ memory_card_kvs

    update_ini(ini_path, "Core", core_kvs)
    update_ini(ini_path, "Display", [{"Fullscreen", "False"}])

    if headless do
      # Mainline capitalizes "Audio", Ishiiruka doesn't (console.py).
      backend = if flavor == :mainline, do: "No Audio Output", else: "No audio output"
      update_ini(ini_path, "DSP", [{"Backend", backend}])
    end

    :ok
  end

  defp bool_str(true), do: "True"
  defp bool_str(false), do: "False"

  ## ------------------------------------------------------------------
  ## Memory card
  ## ------------------------------------------------------------------

  # EXI device ids Dolphin writes for the memory card slots.
  @exi_device_none "255"
  @exi_device_memory_card_folder "8"

  # Memory cards are DISABLED by default. Without save data of its own,
  # Melee opens a "Create Game Data?" dialog at boot; a bot that cannot
  # answer it (see `Melee.MenuHelper`'s `:boot_dialog` option) hangs
  # forever on a scene the spectator stream reports as UNKNOWN_MENU. A
  # bot needs no save data, so the default unplugs both slots.
  #
  #   * `false` (default) — no card in either slot
  #   * `true` — leave the slots exactly as the copied/base config has
  #     them, and provision nothing. This does NOT plug a card in: a home
  #     whose config says `SlotA = 255` still boots without one.
  #   * `:folder` — plug a GCI-folder card into slot A, creating the
  #     directory Dolphin expects. Persists nametags and unlocks across
  #     runs, which `true` alone will not do.
  defp memory_card_kvs(home, opts) do
    case Keyword.get(opts, :memory_card, false) do
      false ->
        [{"SlotA", @exi_device_none}, {"SlotB", @exi_device_none}]

      true ->
        []

      :folder ->
        provision_gci_folder(home, Keyword.get(opts, :memory_card_region, "USA"))
        [{"SlotA", @exi_device_memory_card_folder}]

      other ->
        raise ArgumentError,
              ":memory_card must be false, true or :folder, got: #{inspect(other)}"
    end
  end

  # Dolphin's folder-backed memory card reads GCI files out of
  # `<home>/GC/<region>/Card A`, so the directory has to exist before
  # boot. Melee writes its own save into it on first run.
  defp provision_gci_folder(home, region) do
    home |> gci_folder_path(region) |> File.mkdir_p!()
  end

  @doc """
  Path of the GCI-folder memory card slot A directory for a user
  directory — where `memory_card: :folder` keeps save files.

  ## Examples

      iex> Melee.Dolphin.gci_folder_path("/tmp/home", "USA")
      "/tmp/home/GC/USA/Card A"
  """
  @spec gci_folder_path(Path.t(), String.t()) :: Path.t()
  def gci_folder_path(home, region \\ "USA") do
    Path.join([home, "GC", region, "Card A"])
  end

  ## ------------------------------------------------------------------
  ## Gecko codes (console.py _setup_gecko_codes)
  ## ------------------------------------------------------------------

  defp write_gecko_codes(home, extra_codes) do
    template =
      :libmelee_ex
      |> :code.priv_dir()
      |> Path.join("GALE01r2.ini")
      |> File.read!()

    rendered = String.replace(template, "{extra_codes}", Enum.join(extra_codes, "\n"))

    game_settings = Path.join(home, "GameSettings")
    File.mkdir_p!(game_settings)
    File.write!(Path.join(game_settings, "GALE01r2.ini"), rendered)
  end

  ## ------------------------------------------------------------------
  ## Process control
  ## ------------------------------------------------------------------

  defp start_process(prep) do
    if File.regular?(prep.exe) do
      port =
        Port.open({:spawn_executable, to_charlist(prep.exe)}, [
          :binary,
          :exit_status,
          args: prep.args
        ])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          nil -> nil
        end

      {:ok,
       %__MODULE__{
         port: port,
         os_pid: os_pid,
         exe: prep.exe,
         home: prep.home,
         slippi_port: prep.slippi_port,
         flavor: prep.flavor,
         temp_home?: prep.temp_home?,
         user_json?: Map.get(prep, :user_json?, false)
       }}
    else
      {:error, {:exe_not_found, prep.exe}}
    end
  rescue
    e -> {:error, e}
  end

  defp wait_for_exit(dolphin, timeout_ms) when timeout_ms <= 0, do: not alive?(dolphin)

  defp wait_for_exit(dolphin, timeout_ms) do
    if alive?(dolphin) do
      Process.sleep(100)
      wait_for_exit(dolphin, timeout_ms - 100)
    else
      true
    end
  end

  ## ------------------------------------------------------------------
  ## Minimal INI read-modify-write (mirror of DolphinConfig's private
  ## helpers — kept as a local copy since those are private and that
  ## module must not change).
  ## ------------------------------------------------------------------

  defp update_ini(path, section, entries) do
    File.mkdir_p!(Path.dirname(path))

    sections = if File.exists?(path), do: parse_ini(File.read!(path)), else: []

    sections =
      case List.keyfind(sections, section, 0) do
        nil ->
          sections ++ [{section, entries}]

        {^section, existing} ->
          merged =
            Enum.reduce(entries, existing, fn {k, v}, acc ->
              List.keystore(acc, k, 0, {k, v})
            end)

          List.keyreplace(sections, section, 0, {section, merged})
      end

    File.write!(path, render_ini(sections))
  end

  defp parse_ini(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce([], fn line, acc ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" or String.starts_with?(trimmed, ["#", ";"]) ->
          acc

        String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
          [{String.slice(trimmed, 1..-2//1), []} | acc]

        acc == [] ->
          acc

        true ->
          case String.split(trimmed, "=", parts: 2) do
            [key, value] ->
              [{section, entries} | rest] = acc
              [{section, entries ++ [{String.trim(key), String.trim(value)}]} | rest]

            _ ->
              acc
          end
      end
    end)
    |> Enum.reverse()
  end

  defp render_ini(sections) do
    Enum.map_join(sections, "\n", fn {section, entries} ->
      "[#{section}]\n" <> Enum.map_join(entries, "\n", fn {k, v} -> "#{k} = #{v}" end) <> "\n"
    end)
  end
end
