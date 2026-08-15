defmodule Melee.Session do
  @moduledoc """
  A supervised unit that owns one Dolphin instance, its `Melee.Console`
  and its `Melee.Controller`s — wired together in the one order that
  works.

  Every consumer of this library ends up hand-writing the same startup
  sequence, and the sequence is unforgiving:

    1. **Prepare the home and wire pad config first.** Dolphin reads
       `GCPadNew.ini` and the `SIDevice*` keys once, at boot. Creating a
       controller after launch requires a restart, so the fifos are
       provisioned by `Melee.Dolphin.prepare_home/1` (via
       `:controller_ports`) *before* the process starts.
    2. **Launch Dolphin.**
    3. **Connect the console, with retries.** A lone Dolphin is
       listening within a second, but parallel instances (ISO read and
       shader-cache contention) can take tens of seconds — hence
       `:connect_attempts` with growing backoff.
    4. **Open the controller fifos.** Opening the write end of a fifo
       *blocks* until Dolphin opens the read end, so this must come
       after Dolphin is up, and it must not be done before the console
       connect (which would deadlock a single-threaded startup).
    5. **Register the controllers with the console**, so `step/2` flushes
       them at the top of each frame.

  ## Why a GenServer and not a `Supervisor`

  A `Supervisor` starts children independently and restarts them in
  isolation. Here the children are *interdependent and strictly
  ordered*: a controller cannot be started before Dolphin is running,
  and it must be re-registered with the surviving console after a
  restart. Encoding "restart only this child, then re-run a side effect
  against a sibling" is not something a supervisor's strategies express.
  So `Melee.Session` is a `GenServer` that traps exits and links its
  children, with hand-written restart policy:

    * a **controller** that crashes is restarted (fifo reopened) and
      re-registered with the console;
    * the **console** dying stops the session — a console crash is a bug,
      not a transient condition, and `:reconnect` (see
      `Melee.Console`) already covers transport drops;
    * **Dolphin** exiting stops the session with
      `{:shutdown, {:dolphin_exited, status}}` — there is nothing left
      to connect to.

  ## Port ownership

  `Melee.Dolphin.launch/1` opens an Erlang `Port` owned by its *caller*.
  The session GenServer calls it from `init/1`, so the session process
  owns the port and is the process that receives
  `{port, {:exit_status, n}}`. That is deliberate: the owner must be a
  long-lived process that survives controller restarts and can act on
  Dolphin's death. Do not call `Melee.Dolphin.launch/1` from a
  short-lived caller and hand the struct to a session.

  ## Options

  The union of `Melee.Dolphin.launch/1` options (`:path` and `:iso_path`
  are required) plus:

    * `:ports` — GC ports to create controllers for, default `[1]`.
      Passed on to Dolphin as `:controller_ports`.
    * `:console` — options forwarded to `Melee.Console.start_link/1`
      (e.g. `polling_mode: true`, `reconnect: [attempts: 5]`).
      `:port` defaults to the launched Dolphin's `:slippi_port`.
    * `:connect_attempts` — console connect attempts, default `5`
    * `:connect_backoff_ms` — backoff base; attempt *n* waits
      `n * backoff`, default `2_000`
    * `:connect_timeout` — per-attempt console connect timeout, default
      `10_000`
    * `:controller_connect_timeout` — fifo-open timeout, default `60_000`
    * `:name` — optional GenServer name
    * `:dolphin_module` — testing seam; the module implementing
      `launch/1`, `pipes_path/2` and `stop/1`. Defaults to
      `Melee.Dolphin`.

  ## Example

      {:ok, session} =
        Melee.Session.start_link(
          path: "/opt/slippi",
          iso_path: "/isos/melee.iso",
          headless: true,
          ports: [1, 2],
          console: [polling_mode: true, polling_timeout: 100,
                    reconnect: [attempts: 5]]
        )

      controller = Melee.Session.controller(session, 1)
      {:ok, gamestate} = Melee.Session.step(session, 30_000)
      Melee.Controller.press_button(controller, :a)

      :ok = Melee.Session.stop(session)

  In a supervision tree — `restart: :transient`, so a clean stop (or a
  Dolphin exit, which is a `:shutdown`) does not restart it:

      children = [
        {Melee.Session,
         name: MyApp.Session, path: dolphin, iso_path: iso, ports: [1]}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """

  use GenServer

  require Logger

  alias Melee.{Console, Controller}

  @type t :: GenServer.server()

  @session_keys [
    :ports,
    :console,
    :name,
    :connect_attempts,
    :connect_backoff_ms,
    :connect_timeout,
    :controller_connect_timeout,
    :dolphin_module
  ]

  ## Client API

  @doc """
  Start a session: prepare the home, launch Dolphin, connect the console
  and open + register the controllers. Returns once the whole unit is
  live, or `{:error, reason}` if any step fails (already-started pieces
  are torn down first).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc """
  Child spec for a supervision tree.

  `restart: :transient` — a session that stopped normally, or because
  Dolphin exited (`{:shutdown, _}`), should stay stopped.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 15_000
    }
  end

  @doc "Advance one frame. Delegates to `Melee.Console.step/2`."
  @spec step(t(), timeout()) :: Console.step_result()
  def step(session, timeout \\ :infinity),
    do: session |> console() |> Console.step(timeout)

  @doc "The `Melee.Controller` pid for a GC port, or `nil`."
  @spec controller(t(), pos_integer()) :: pid() | nil
  def controller(session, port), do: GenServer.call(session, {:controller, port})

  @doc "The underlying `Melee.Console` pid — nothing is hidden."
  @spec console(t()) :: pid()
  def console(session), do: GenServer.call(session, :console)

  @doc "The underlying `Melee.Dolphin` struct."
  @spec dolphin(t()) :: Melee.Dolphin.t()
  def dolphin(session), do: GenServer.call(session, :dolphin)

  @doc """
  Tear the session down (controllers, then console, then Dolphin).
  Idempotent: stopping an already-dead session is `:ok`.
  """
  @spec stop(t()) :: :ok
  def stop(session) do
    GenServer.stop(session, :normal, 30_000)
  catch
    :exit, _ -> :ok
  end

  ## GenServer implementation

  defmodule State do
    @moduledoc false
    defstruct [
      :dolphin,
      :dolphin_module,
      :console,
      :controller_connect_timeout,
      ports: [],
      # %{gc_port => %{pid: pid, pipe: path}}
      controllers: %{},
      # Tail of Dolphin's captured stdout+stderr, kept for the exit log
      # — that's where crash evidence ("A signal was received", backend
      # failures) lands.
      dolphin_output: ""
    ]

    @type t :: %__MODULE__{}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {session_opts, launch_opts} = Keyword.split(opts, @session_keys)
    ports = Keyword.get(session_opts, :ports, [1])
    dolphin_module = Keyword.get(session_opts, :dolphin_module, Melee.Dolphin)

    state = %State{
      dolphin_module: dolphin_module,
      ports: ports,
      controller_connect_timeout: Keyword.get(session_opts, :controller_connect_timeout, 60_000)
    }

    case dolphin_module.launch(Keyword.put(launch_opts, :controller_ports, ports)) do
      {:ok, dolphin} -> boot(%{state | dolphin: dolphin}, session_opts)
      {:error, reason} -> {:stop, reason}
    end
  end

  # Console then controllers, aborting to a clean stop on the first
  # failure. `terminate/2` does NOT run when `init/1` returns `:stop`,
  # and the console/controllers are *linked* so they die with us — but
  # Dolphin is an OS process behind a Port, so it must be killed by hand
  # or a half-built session leaks an emulator.
  @spec boot(State.t(), keyword()) :: {:ok, State.t()} | {:stop, term()}
  defp boot(state, session_opts) do
    with {:ok, state} <- start_console(state, session_opts),
         {:ok, state} <- start_controllers(state) do
      {:ok, state}
    else
      {:error, reason} ->
        safely(fn -> state.dolphin_module.stop(state.dolphin) end)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:console, _from, state), do: {:reply, state.console, state}
  def handle_call(:dolphin, _from, state), do: {:reply, state.dolphin, state}

  def handle_call({:controller, port}, _from, state),
    do: {:reply, get_in(state.controllers, [port, :pid]), state}

  @impl true
  def handle_info({port, {:data, data}}, %{dolphin: %{port: port}} = state)
      when is_port(port) do
    {:noreply, %{state | dolphin_output: output_tail(state.dolphin_output <> data)}}
  end

  def handle_info({port, {:exit_status, status}}, %{dolphin: %{port: port}} = state)
      when is_port(port) do
    tail =
      case state.dolphin_output do
        "" -> ""
        out -> "; last output:\n" <> out
      end

    Logger.warning(
      "Melee.Session: Dolphin exited with status #{status}; stopping session" <> tail
    )

    {:stop, {:shutdown, {:dolphin_exited, status}},
     %{state | dolphin: %{state.dolphin | port: nil}}}
  end

  def handle_info({:EXIT, pid, reason}, %{console: pid} = state) do
    Logger.warning("Melee.Session: console died (#{inspect(reason)}); stopping session")
    {:stop, {:shutdown, {:console_died, reason}}, %{state | console: nil}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.controllers, fn {_port, c} -> c.pid == pid end) do
      nil -> {:noreply, state}
      {gc_port, entry} -> restart_controller(state, gc_port, entry, reason)
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Same cap as Melee.Dolphin.watch/2: enough for crash evidence,
  # small enough to log.
  @output_tail_bytes 2_048

  defp output_tail(tail) when byte_size(tail) <= @output_tail_bytes, do: tail

  defp output_tail(tail),
    do: binary_part(tail, byte_size(tail) - @output_tail_bytes, @output_tail_bytes)

  @impl true
  def terminate(_reason, state), do: teardown(state)

  ## Startup steps

  @spec start_console(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  defp start_console(state, session_opts) do
    console_opts =
      session_opts
      |> Keyword.get(:console, [])
      |> Keyword.put_new(:port, state.dolphin.slippi_port)

    with {:ok, console} <- Console.start_link(console_opts),
         :ok <-
           connect_console(
             console,
             Keyword.get(session_opts, :connect_attempts, 5),
             Keyword.get(session_opts, :connect_backoff_ms, 2_000),
             Keyword.get(session_opts, :connect_timeout, 10_000)
           ) do
      {:ok, %{state | console: console}}
    end
  end

  # A lone Dolphin listens quickly; parallel instances boot slowly. Wait
  # `n * backoff` before attempt n + 1 (2s, 4s, 6s, 8s by default ≈ 20s
  # of patience plus the connect timeouts).
  @spec connect_console(pid(), pos_integer(), pos_integer(), timeout()) :: :ok | {:error, term()}
  defp connect_console(console, attempts, backoff_ms, timeout) do
    Enum.reduce_while(1..attempts, {:error, :never_tried}, fn attempt, _acc ->
      case Console.connect(console, timeout) do
        :ok ->
          {:halt, :ok}

        {:error, reason} when attempt < attempts ->
          wait = backoff_ms * attempt

          Logger.warning(
            "Melee.Session: console connect attempt #{attempt}/#{attempts} failed " <>
              "(#{inspect(reason)}); retrying in #{wait}ms"
          )

          Process.sleep(wait)
          {:cont, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, {:console_connect_failed, reason}}}
      end
    end)
  end

  @spec start_controllers(State.t()) :: {:ok, State.t()} | {:error, term()}
  defp start_controllers(state) do
    Enum.reduce_while(state.ports, {:ok, state}, fn gc_port, {:ok, state} ->
      pipe = state.dolphin_module.pipes_path(state.dolphin, gc_port)

      case open_controller(state, pipe) do
        {:ok, pid} ->
          {:cont, {:ok, put_in(state.controllers[gc_port], %{pid: pid, pipe: pipe})}}

        {:error, reason} ->
          {:halt, {:error, {:controller_failed, gc_port, reason}}}
      end
    end)
  end

  # Opening the write end of a fifo blocks until Dolphin opens the read
  # end, so this happens only after Dolphin is running.
  @spec open_controller(State.t(), Path.t()) :: {:ok, pid()} | {:error, term()}
  defp open_controller(state, pipe) do
    with {:ok, pid} <- Controller.start_link(pipe_path: pipe),
         :ok <- Controller.connect(pid, state.controller_connect_timeout),
         :ok <- Console.register_controller(state.console, pid) do
      {:ok, pid}
    end
  end

  ## Restart policy

  @spec restart_controller(State.t(), pos_integer(), map(), term()) ::
          {:noreply, State.t()} | {:stop, term(), State.t()}
  defp restart_controller(state, gc_port, entry, reason) do
    Logger.warning(
      "Melee.Session: controller on port #{gc_port} died (#{inspect(reason)}); restarting"
    )

    # The console still holds the dead pid; drop it before adding the new
    # one so `step/2` never flushes a corpse.
    Console.unregister_controller(state.console, entry.pid)

    case open_controller(state, entry.pipe) do
      {:ok, pid} ->
        {:noreply, put_in(state.controllers[gc_port], %{entry | pid: pid})}

      {:error, restart_reason} ->
        {:stop, {:shutdown, {:controller_restart_failed, gc_port, restart_reason}},
         %{state | controllers: Map.delete(state.controllers, gc_port)}}
    end
  end

  ## Teardown — reverse order, tolerant of already-dead pieces

  @spec teardown(State.t()) :: :ok
  defp teardown(state) do
    Enum.each(state.controllers, fn {_port, %{pid: pid}} ->
      safely(fn -> Controller.disconnect(pid) end)
    end)

    if state.console, do: safely(fn -> Console.stop(state.console) end)
    if state.dolphin, do: safely(fn -> state.dolphin_module.stop(state.dolphin) end)
    :ok
  end

  @spec safely((-> any())) :: :ok
  defp safely(fun) do
    fun.()
    :ok
  catch
    :exit, _ -> :ok
    kind, error -> Logger.warning("Melee.Session teardown: #{inspect(kind)} #{inspect(error)}")
  end
end
