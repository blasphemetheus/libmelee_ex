defmodule Melee.SessionPool do
  @moduledoc """
  N parallel `Melee.Session`s under one supervisor — the eval-farm shape.

  Protocol rules that demand n>=8 run-level replications make eval
  throughput the bottleneck once single runs are reliable; the only
  things stopping N headless Dolphins from coexisting are the shared
  resources, and each has a per-instance answer:

    * **Slippi spectator port** — every instance gets its own free UDP
      port, probed upward from `:base_port` (default 51441, Slippi's
      own default). The port each session actually got is readable off
      its Dolphin struct.
    * **Dolphin home** — with a `:home` in the session opts, instance
      `i` runs in `home/s<i>`; without one, `Melee.Dolphin.launch/1`
      already provisions a temp home per instance.
    * **GC adapter** — never contended: `declare_ports/2` unplugs
      undeclared ports, and pool sessions declare none as
      `:gcn_adapter`.

  ## Usage

      {:ok, pool} =
        Melee.SessionPool.start_link(
          count: 4,
          session: [
            path: "/opt/slippi", iso_path: "/isos/melee.iso",
            headless: true, ports: [1, 2]
          ]
        )

      for {i, session} <- Melee.SessionPool.sessions(pool) do
        {:ok, gamestate} = Melee.Session.step(session, 30_000)
        ...
      end

  Children are `restart: :transient` (a session whose Dolphin exits
  stays down) under `:one_for_one` — one crashed instance never
  restarts its siblings' emulators. Startup is sequential: each session
  blocks until its whole unit (Dolphin + console + controllers) is
  live, which also keeps N Dolphin boots from stampeding the machine.
  """

  use Supervisor

  @default_base_port 51_441

  @doc """
  Start `:count` sessions (required). `:session` is the base option list
  every instance shares (everything `Melee.Session.start_link/1`
  accepts); `:base_port` (default #{@default_base_port}) seeds the UDP
  port probe; `:name` names the supervisor.

  Do not pass `:slippi_port` in `:session` — per-instance allocation is
  the point — and a shared `:name` is meaningless for N sessions;
  address instances via `sessions/1` / `session/2`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    {sup_opts, opts} = Keyword.split(opts, [:name])
    Supervisor.start_link(__MODULE__, opts, sup_opts)
  end

  @impl true
  def init(opts) do
    count = Keyword.fetch!(opts, :count)
    base_session = Keyword.get(opts, :session, [])
    base_port = Keyword.get(opts, :base_port, @default_base_port)

    if Keyword.has_key?(base_session, :slippi_port) do
      raise ArgumentError,
            "don't pass :slippi_port in :session — the pool allocates one per instance"
    end

    if Keyword.has_key?(base_session, :name) do
      raise ArgumentError,
            "don't pass :name in :session — address instances via SessionPool.sessions/1"
    end

    {children, _next_port} =
      Enum.map_reduce(1..count, base_port, fn i, candidate_port ->
        port = free_udp_port(candidate_port)

        session_opts =
          base_session
          |> Keyword.put(:slippi_port, port)
          |> instance_home(i)

        spec = Supervisor.child_spec({Melee.Session, session_opts}, id: {:session, i})
        {spec, port + 1}
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "All live sessions as `[{index, pid}]`, index-ordered."
  @spec sessions(Supervisor.supervisor()) :: [{pos_integer(), pid()}]
  def sessions(pool) do
    for {{:session, i}, pid, _type, _mods} <- Supervisor.which_children(pool),
        is_pid(pid) do
      {i, pid}
    end
    |> Enum.sort()
  end

  @doc "The session with index `i`, or `nil` if it is not running."
  @spec session(Supervisor.supervisor(), pos_integer()) :: pid() | nil
  def session(pool, i) do
    Enum.find_value(sessions(pool), fn
      {^i, pid} -> pid
      _ -> nil
    end)
  end

  # A shared :home would make N Dolphins fight over one user directory
  # (config, pipes, memory cards); give instance i its own subdirectory.
  # No :home at all is fine — Dolphin.launch provisions a temp home.
  defp instance_home(session_opts, i) do
    case Keyword.get(session_opts, :home) do
      nil ->
        session_opts

      home ->
        instance = Path.join(home, "s#{i}")
        File.mkdir_p!(instance)
        Keyword.put(session_opts, :home, instance)
    end
  end

  # First bindable UDP port at or above `candidate`. Probe-then-release
  # has a race window, but candidates come pre-spread (one per instance)
  # and Slippi only needs the port free at Dolphin boot.
  defp free_udp_port(candidate) when candidate < 65_535 do
    case :gen_udp.open(candidate, [:binary]) do
      {:ok, socket} ->
        :gen_udp.close(socket)
        candidate

      {:error, _} ->
        free_udp_port(candidate + 1)
    end
  end
end
