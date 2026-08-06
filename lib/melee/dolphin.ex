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
  """

  alias Melee.DolphinConfig

  @enforce_keys [:exe, :home, :slippi_port, :flavor, :temp_home?]
  defstruct [:port, :os_pid, :exe, :home, :slippi_port, :flavor, :temp_home?]

  @typedoc """
  A running (or launched-then-stopped) Dolphin instance.

    * `:port` — the Erlang `Port` (nil after `stop/1`)
    * `:os_pid` — OS pid of the Dolphin process
    * `:exe` — resolved executable path
    * `:home` — Dolphin user directory in use
    * `:slippi_port` — spectator UDP port Slippi listens on
    * `:flavor` — `:ishiiruka` or `:mainline`
    * `:temp_home?` — whether we created `:home` and delete it on `stop/1`
  """
  @type t :: %__MODULE__{
          port: port() | nil,
          os_pid: pos_integer() | nil,
          exe: Path.t(),
          home: Path.t(),
          slippi_port: pos_integer(),
          flavor: :ishiiruka | :mainline,
          temp_home?: boolean()
        }

  @type flavor :: :ishiiruka | :mainline
  @type launch_opt ::
          {:path, Path.t()}
          | {:iso_path, Path.t()}
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

  # Linux executable names inside a Slippi Launcher install dir
  # (console.py get_exe_path).
  @ishiiruka_exe "Slippi_Online-x86_64.AppImage"
  @mainline_exe "Slippi_Netplay_Mainline-x86_64.AppImage"

  ## ------------------------------------------------------------------
  ## Launch / lifecycle
  ## ------------------------------------------------------------------

  @doc """
  Set up a Dolphin user directory and start the Dolphin process.

  See the module doc for option semantics; `:path` and `:iso_path` are
  required. Returns `{:ok, t}` with the Port owned by the caller (the
  caller receives `{port, {:exit_status, n}}` when Dolphin exits).
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
  `:flavor`, `:temp_home?`, `:slippi_port`, and `:args` (full argv after
  the executable). Useful for tests and for wiring controllers into the
  home before launching.
  """
  @spec prepare_home([launch_opt()]) ::
          {:ok,
           %{
             exe: Path.t(),
             home: Path.t(),
             flavor: flavor(),
             temp_home?: boolean(),
             slippi_port: pos_integer(),
             args: [String.t()]
           }}
          | {:error, term()}
  def prepare_home(opts) do
    with {:ok, path} <- require_opt(opts, :path),
         {:ok, iso_path} <- require_opt(opts, :iso_path),
         {:ok, exe, flavor} <- resolve_exe(path, Keyword.get(opts, :flavor, :auto)),
         {:ok, home, temp_home?} <- setup_home_dir(opts) do
      headless = Keyword.get(opts, :headless, false)
      slippi_port = Keyword.get(opts, :slippi_port, @default_slippi_port)

      write_dolphin_ini(home, flavor, slippi_port, headless, opts)

      if Keyword.get(opts, :setup_gecko_codes, true) do
        write_gecko_codes(home, Keyword.get(opts, :gecko_extra_codes, []))
      end

      # Bot controllers must be wired in BEFORE the process starts —
      # Dolphin reads pad config at boot.
      for port <- Keyword.get(opts, :controller_ports, []) do
        {:ok, _pipe} = DolphinConfig.setup_controller(home, port, :standard)
      end

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
         args: args
       }}
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
    save_replays = Keyword.get(opts, :save_replays, false)
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
           ] ++ if(replay_dir, do: [{"ReplayDir", replay_dir}], else: [])}

        :ishiiruka ->
          {"Core",
           [
             {"SlippiEnableSpectator", "True"},
             {"SlippiSpectatorLocalPort", to_string(slippi_port)},
             {"SlippiOnlineDelay", to_string(online_delay)},
             {"BlockingPipes", bool_str(blocking_input)},
             {"SlippiSaveReplays", bool_str(save_replays)}
           ] ++ if(replay_dir, do: [{"SlippiReplayDir", replay_dir}], else: [])}
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
         temp_home?: prep.temp_home?
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

  defp require_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_option, key, value}}
      :error -> {:error, {:missing_option, key}}
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
