defmodule Melee.MemoryWatcher do
  @moduledoc """
  Client for Dolphin's MemoryWatcher: named, typed, subscribable reads
  of Melee's RAM while a session runs.

  Dolphin ships a tiny facility (see slippi-Ishiiruka
  `Source/Core/Core/MemoryWatcher.cpp`, present and verified working in
  the mainline-beta netplay build, 2026-08-22 spike): if
  `User/MemoryWatcher/Locations.txt` exists at core start, every line —
  a hex address, or a space-separated pointer chain — is polled 600
  times a second, and each CHANGE is sent as a datagram
  `"<line>\\n<hexvalue>\\0"` to a Unix socket at
  `User/MemoryWatcher/MemoryWatcher` that the client must have bound.

  This module is that client:

      {:ok, w} =
        Melee.MemoryWatcher.start_link(
          home: home,
          watches: [rng_seed: "804D5F90", css_p1_char: "8043208B"]
        )

      # ... THEN launch Dolphin with the same :home ...

      Melee.MemoryWatcher.get(w, :rng_seed)        #=> {:ok, 0xAF83BC16}
      Melee.MemoryWatcher.get_f32(w, :css_p1_x)    #=> {:ok, -23.04}
      Melee.MemoryWatcher.subscribe(w, :rng_seed)  # {:memory_watch, :rng_seed, value}

  ## Ordering contract

  `start_link` writes `Locations.txt` and binds the socket, so the
  watcher MUST be started before Dolphin launches with that home:
  Dolphin reads the file once at core start and sendto's the socket
  path unconditionally (missed datagrams are silently dropped, and a
  file written after boot is never read).

  ## Semantics worth knowing

    * Values arrive ON CHANGE only. `get/2` returns `:unknown` until
      the first change after boot — for constantly-ticking addresses
      (RNG seed) that is milliseconds; for static ones it can be never.
      Watch something that transitions, or treat `:unknown` as "initial
      value not yet observed".
    * Reads are u32. `get_f32/2` reinterprets the same 4 bytes as a
      big-endian IEEE float (Melee is big-endian PowerPC).
    * Pointer chains ("80453080 2C 70") follow Dolphin's own semantics:
      value = Read_U32(0); for each offset, value = Read_U32(value +
      offset). A chain whose base is unmapped reads 0.
    * The stream carries occasional junk frames (bare `"\\0"` datagrams
      were observed live); the parser drops anything that doesn't frame
      as line+newline+hex.
  """

  use GenServer

  require Logger

  @type watch_name :: atom() | String.t()

  ## Client API

  @doc """
  Start a watcher for `home` (the Dolphin user dir the session will
  use). `watches` is a keyword/list: `[name: "hexline"]`, or bare
  hex-line strings (the line doubles as the name).
  """
  def start_link(opts) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc "Latest u32 for a watch, or `:unknown` before its first change."
  @spec get(GenServer.server(), watch_name()) :: {:ok, non_neg_integer()} | :unknown
  def get(watcher, name), do: GenServer.call(watcher, {:get, name})

  @doc """
  Latest value reinterpreted as a big-endian f32. TOTAL over all u32
  bit patterns: NaN/infinity bits (possible when a watch points at a
  stale or non-float address) decode to `:nan` / `:infinity` /
  `:neg_infinity` instead of crashing (Elixir's float binary match
  rejects them — found by the input-class battery, 2026-08-22).
  """
  @spec get_f32(GenServer.server(), watch_name()) ::
          {:ok, float() | :nan | :infinity | :neg_infinity} | :unknown
  def get_f32(watcher, name) do
    with {:ok, u32} <- get(watcher, name) do
      case <<u32::32>> do
        <<f::float-big-32>> -> {:ok, f}
        <<0::1, 0xFF::8, 0::23>> -> {:ok, :infinity}
        <<1::1, 0xFF::8, 0::23>> -> {:ok, :neg_infinity}
        _ -> {:ok, :nan}
      end
    end
  end

  @doc "All known values as `%{name => u32}`. `timeout` bounds the call."
  def snapshot(watcher, timeout \\ 5000), do: GenServer.call(watcher, :snapshot, timeout)

  @doc """
  Monotone count of datagrams received since start — PARSE-INDEPENDENT
  (junk and bare-NUL empty-step frames count). Dolphin sends a datagram
  EVERY step while game frames advance, so a positive delta between two
  reads is ground truth for "the core is running and paced", even when
  no watched value changes. The liveness ratchet
  (MEMORY_WATCH_PROGRAM app #12).
  """
  @spec traffic(GenServer.server()) :: non_neg_integer()
  def traffic(watcher), do: GenServer.call(watcher, :traffic)

  @doc """
  Subscribe the calling process: it receives
  `{:memory_watch, name, u32}` on every change of that watch (`:all`
  subscribes to every watch). Subscriptions die with the subscriber.
  """
  def subscribe(watcher, name \\ :all), do: GenServer.call(watcher, {:subscribe, name, self()})

  def stop(watcher), do: GenServer.stop(watcher)

  @doc "Low-level `:socket.info/1` of the bound socket (debugging)."
  def debug_info(watcher), do: GenServer.call(watcher, :debug_info)

  ## Pure helpers (unit-tested)

  @doc false
  def render_locations(watches) do
    watches
    |> normalize_watches()
    |> Enum.map_join("\n", fn {_name, line} -> line end)
    |> Kernel.<>("\n")
  end

  @doc false
  def normalize_watches(watches) do
    Enum.map(watches, fn
      {name, line} when is_binary(line) -> {name, normalize_line(line)}
      line when is_binary(line) -> {line, normalize_line(line)}
    end)
  end

  # Dolphin's ParseLine round-trips the line verbatim as the datagram
  # key, so normalization (trim + collapse spaces) must happen BEFORE
  # the file is written or keys won't match.
  defp normalize_line(line), do: line |> String.split() |> Enum.join(" ")

  @doc false
  @spec parse_datagram(binary()) :: {:ok, [{String.t(), non_neg_integer()}]} | :error
  def parse_datagram(data) do
    # Mainline-slippi dolphin sends a COMPOSITE per step: zero or more
    # "line\nhexvalue\n" pairs, then a NUL — an empty step is a bare
    # "\0" (observed live at high rate). Ishiiruka's classic
    # "line\nhexvalue\0" (no trailing newline) parses through the same
    # path. THE 2026-08-22 FIELD BUG lived here: a two-part-only parser
    # rejected every real mainline message over the trailing newline.
    parts =
      data
      |> String.trim_trailing(<<0>>)
      |> String.split("\n")
      |> then(fn p -> if List.last(p) == "", do: Enum.drop(p, -1), else: p end)

    case parts do
      [] ->
        :error

      _ ->
        parts
        |> Enum.chunk_every(2)
        |> Enum.reduce_while([], fn
          [line, hex], acc ->
            case Integer.parse(hex, 16) do
              {value, ""} -> {:cont, [{line, value} | acc]}
              _ -> {:halt, :error}
            end

          _odd, _acc ->
            {:halt, :error}
        end)
        |> case do
          :error -> :error
          [] -> :error
          updates -> {:ok, Enum.reverse(updates)}
        end
    end
  end

  ## GenServer

  @impl true
  def init(opts) do
    home = opts |> Keyword.fetch!(:home) |> Path.expand()
    watches = normalize_watches(Keyword.get(opts, :watches, []))

    if watches == [], do: raise(ArgumentError, ":watches must not be empty")

    dir = Path.join(home, "MemoryWatcher")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Locations.txt"), render_locations(watches))

    sock_path = Path.join(dir, "MemoryWatcher")
    File.rm(sock_path)

    # The RECEIVER process owns the socket end-to-end (open, bind, recv
    # loop) — mirroring the validated spike's process anatomy.
    # Synchronous handshake so init fails loudly if the bind does.
    parent = self()

    {:ok, receiver} =
      Task.start_link(fn ->
        {:ok, sock} = :socket.open(:local, :dgram, :default)
        :ok = :socket.bind(sock, %{family: :local, path: sock_path})
        send(parent, {:mw_bound, self(), sock})
        recv_loop(sock, parent)
      end)

    sock =
      receive do
        {:mw_bound, ^receiver, s} -> s
      after
        5_000 -> raise "MemoryWatcher receiver failed to bind #{sock_path}"
      end

    {:ok,
     %{
       sock: sock,
       receiver: receiver,
       # datagram key (the verbatim line) -> watch name
       names: Map.new(watches, fn {name, line} -> {line, name} end),
       values: %{},
       subs: %{},
       traffic: 0
     }}
  end

  # Finite timeout + explicit buffer, NEVER `recvfrom(sock, 0,
  # :infinity)`: under load from an external sender the infinity path
  # truncated datagrams to ~1 byte (NIF counters showed 323 pkgs / 388
  # bytes while dolphin streamed 18-byte messages — 2026-08-22 hunt).
  # The timeout-loop shape is the one the working spike used.
  #
  # Buffer sized for BATCH watching: dolphin composites every changed
  # entry into ONE datagram per step (~18 bytes/entry), so a 100-line
  # hunt batch under churn runs ~2KB — the original 2048 buffer
  # TRUNCATED those, the parser rejected the mangled frame, and every
  # update in it silently dropped while empty-step traffic kept the
  # liveness counter climbing ("driven movers: 0" with healthy
  # traffic, 2026-08-22 hunt run 2). 64KB covers any Locations.txt
  # dolphin will realistically poll.
  defp recv_loop(sock, parent) do
    case :socket.recvfrom(sock, 65_536, 10_000) do
      {:ok, {_src, data}} ->
        send(parent, {:mw_datagram, data})
        recv_loop(sock, parent)

      {:error, :timeout} ->
        recv_loop(sock, parent)

      {:error, reason} ->
        Logger.warning("[MemoryWatcher] socket closed: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_info({:mw_datagram, data}, state) do
    state =
      state
      |> Map.update!(:traffic, &(&1 + 1))
      |> Map.update(:raw_ring, [data], fn r -> Enum.take([data | r], 5) end)

    case parse_datagram(data) do
      {:ok, updates} ->
        state =
          Enum.reduce(updates, state, fn {line, value}, st ->
            case Map.fetch(st.names, line) do
              {:ok, name} ->
                notify(st.subs, name, value)
                put_in(st.values[name], value)

              :error ->
                # A line we didn't register — stale Locations.txt from
                # a previous session in a reused home. Keep under the
                # raw line key; harmless.
                put_in(st.values[line], value)
            end
          end)

        {:noreply, state}

      :error ->
        # Empty-step frame (bare "\0", sent every unchanged step) or
        # junk — drop.
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subs =
      state.subs
      |> Enum.map(fn {name, pids} -> {name, MapSet.delete(pids, pid)} end)
      |> Map.new()

    {:noreply, %{state | subs: subs}}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    reply =
      case Map.fetch(state.values, name) do
        {:ok, v} -> {:ok, v}
        :error -> :unknown
      end

    {:reply, reply, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state.values, state}

  def handle_call(:traffic, _from, state), do: {:reply, state.traffic, state}

  def handle_call(:debug_info, _from, state) do
    {:reply, %{socket: :socket.info(state.sock), raw_ring: Map.get(state, :raw_ring, [])}, state}
  end

  def handle_call({:subscribe, name, pid}, _from, state) do
    Process.monitor(pid)
    subs = Map.update(state.subs, name, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | subs: subs}}
  end

  defp notify(subs, name, value) do
    for key <- [name, :all],
        pid <- Map.get(subs, key, []) do
      send(pid, {:memory_watch, name, value})
    end
  end
end