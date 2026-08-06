defmodule Melee.Console do
  @moduledoc """
  A connection to a running Slippi Dolphin instance.

  Mirrors libmelee's `Console`: `connect/2` establishes the ENet +
  Slippstream handshake, then `step/2` yields one `Melee.GameState` per
  frame (flushing any registered controllers first, preserving libmelee's
  flush-at-top-of-step ordering that blocking-input mode depends on).

  ## Options (`start_link/1`)

    * `:address` — Dolphin host, default `"127.0.0.1"`
    * `:port` — Slippi spectator port, default `51441`
    * `:transport` — `Melee.Transport` implementation, default
      `Melee.Transport.EnetNif`
    * `:transport_opts` — extra options for `c:Melee.Transport.connect/4`
    * `:skip_rollback_frames` — default `true`
    * `:blocking_input` — flush controllers on skipped rollback frames so
      a blocking-input Dolphin doesn't hang; default `true`
    * `:polling_mode` — `step/2` returns `nil` when no frame arrives
      within `:polling_timeout` ms (default `0`) instead of waiting
    * `:reconnect` — `false` (default) or a keyword list; see below

  ## Reconnect (opt-in)

  By default a transport disconnect is **terminal**: the console latches
  and every later `step/2` returns `{:error, :enet_disconnected}`, which
  is exactly what Python libmelee does (`EnetDisconnected`).

  Passing `reconnect: [attempts: 5, backoff_ms: 1_000, max_backoff_ms:
  10_000, connect_timeout: 10_000]` instead makes a mid-stream drop
  recoverable: the console re-runs the transport connect and the
  Slippstream handshake with capped exponential backoff
  (`min(backoff_ms * 2 ** (attempt - 1), max_backoff_ms)`). A `step/2`
  in flight waits for the outcome instead of erroring — subject to the
  caller's own timeout, and to `:polling_timeout` in polling mode. If
  every attempt fails the console latches exactly as it does today.

  A reconnect is a **new game stream**, so the console resets its
  `Melee.Events` parser (payload-size table, partial-frame buffer, frame
  counter), drops queued frames, and clears the peer info until the new
  `connect_reply` arrives. Registered controllers are *not* reset: they
  are separate processes writing to Dolphin's fifos, they outlive the
  ENet connection, and they stay registered across the reconnect.

  Failures during the *initial* `connect/2` are never retried here —
  `connect/2` reports them to its caller, which decides.

  ## Example

      {:ok, console} = Melee.Console.start_link([])
      {:ok, controller} = Melee.Controller.start_link(pipe_path: pipe)
      :ok = Melee.Console.connect(console)
      :ok = Melee.Console.register_controller(console, controller)
      :ok = Melee.Controller.connect(controller)

      {:ok, gamestate} = Melee.Console.step(console)
  """

  use GenServer

  require Logger

  alias Melee.{Controller, Events, GameState, Slippstream}

  @type step_result :: {:ok, GameState.t()} | nil | {:error, :enet_disconnected}

  @typedoc """
  Reconnect policy: `false` disables it (the default), a keyword list
  enables it. Keys: `:attempts`, `:backoff_ms`, `:max_backoff_ms`,
  `:connect_timeout`.
  """
  @type reconnect_opt :: false | keyword()

  ## Client API

  @doc "Start a console process (does not connect yet)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc """
  Connect to Dolphin: ENet handshake, then the Slippstream connect
  request. Returns once the ENet connection is up.
  """
  @spec connect(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def connect(console, timeout \\ 10_000),
    do: GenServer.call(console, {:connect, timeout}, timeout_plus(timeout))

  @doc """
  Advance to the next frame.

  Flushes registered controllers, then blocks until a frame completes
  (or, in polling mode, returns `nil` after `:polling_timeout` with no
  frame). Returns `{:error, :enet_disconnected}` once the connection
  drops — the same signal libmelee raises as `EnetDisconnected`.
  """
  @spec step(GenServer.server(), timeout()) :: step_result()
  def step(console, timeout \\ :infinity),
    do: GenServer.call(console, :step, timeout_plus(timeout))

  @doc "Register a `Melee.Controller` to be flushed by `step/2`."
  @spec register_controller(GenServer.server(), GenServer.server()) :: :ok
  def register_controller(console, controller),
    do: GenServer.call(console, {:register_controller, controller})

  @doc """
  Stop flushing a previously registered `Melee.Controller`.

  Useful when a controller process is replaced (see `Melee.Session`,
  which restarts crashed controllers). Unregistering something that was
  never registered is a no-op.
  """
  @spec unregister_controller(GenServer.server(), GenServer.server()) :: :ok
  def unregister_controller(console, controller),
    do: GenServer.call(console, {:unregister_controller, controller})

  @doc "Has the Slippstream `connect_reply` been received?"
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(console), do: GenServer.call(console, :connected?)

  @doc "Peer info from the connect reply: `%{nick, version, cursor}`."
  @spec info(GenServer.server()) :: %{nick: String.t(), version: String.t(), cursor: integer()}
  def info(console), do: GenServer.call(console, :info)

  @doc "Disconnect and stop the console."
  @spec stop(GenServer.server()) :: :ok
  def stop(console), do: GenServer.stop(console, :normal)

  defp timeout_plus(:infinity), do: :infinity
  defp timeout_plus(ms), do: ms + 1_000

  ## GenServer implementation

  defmodule Reconnect do
    @moduledoc false
    defstruct attempts: 5, backoff_ms: 1_000, max_backoff_ms: 10_000, connect_timeout: 10_000

    @type t :: %__MODULE__{
            attempts: non_neg_integer(),
            backoff_ms: pos_integer(),
            max_backoff_ms: pos_integer(),
            connect_timeout: pos_integer()
          }
  end

  defmodule State do
    @moduledoc false
    defstruct transport: Melee.Transport.EnetNif,
              transport_opts: [],
              address: "127.0.0.1",
              port: 51_441,
              conn: nil,
              connect_from: nil,
              parser: nil,
              frames: :queue.new(),
              step_from: nil,
              poll_timer: nil,
              controllers: [],
              connected: false,
              nick: "",
              version: "",
              cursor: 0,
              disconnected: false,
              blocking_input: true,
              polling_mode: false,
              polling_timeout: 0,
              parser_opts: [],
              reconnect: nil,
              reconnecting?: false,
              attempt: 0,
              reconnect_timer: nil

    @type t :: %__MODULE__{}
  end

  @impl true
  def init(opts) do
    parser_opts = [skip_rollback_frames: Keyword.get(opts, :skip_rollback_frames, true)]

    state = %State{
      transport: Keyword.get(opts, :transport, Melee.Transport.EnetNif),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      address: Keyword.get(opts, :address, "127.0.0.1"),
      port: Keyword.get(opts, :port, 51_441),
      parser_opts: parser_opts,
      parser: Events.new(parser_opts),
      blocking_input: Keyword.get(opts, :blocking_input, true),
      polling_mode: Keyword.get(opts, :polling_mode, false),
      polling_timeout: Keyword.get(opts, :polling_timeout, 0),
      reconnect: normalize_reconnect(Keyword.get(opts, :reconnect, false))
    }

    {:ok, state}
  end

  # Data definition: the reconnect option is `false | keyword()`, and the
  # internal representation is `nil | %Reconnect{}`.
  @spec normalize_reconnect(reconnect_opt() | nil) :: Reconnect.t() | nil
  defp normalize_reconnect(falsy) when falsy in [false, nil], do: nil
  defp normalize_reconnect(opts) when is_list(opts), do: struct!(Reconnect, opts)

  @impl true
  def handle_call({:connect, _timeout}, from, state) do
    case state.transport.connect(state.address, state.port, self(), state.transport_opts) do
      {:ok, conn} -> {:noreply, %{state | conn: conn, connect_from: from}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:step, from, state) do
    state = flush_controllers(state)

    case pop_frame(state) do
      {frame, state} ->
        {:reply, {:ok, frame}, state}

      nil when state.disconnected ->
        {:reply, {:error, :enet_disconnected}, state}

      nil when state.polling_mode ->
        timer = Process.send_after(self(), :poll_timeout, state.polling_timeout)
        {:noreply, %{state | step_from: from, poll_timer: timer}}

      nil ->
        {:noreply, %{state | step_from: from}}
    end
  end

  def handle_call({:register_controller, controller}, _from, state),
    do: {:reply, :ok, %{state | controllers: state.controllers ++ [controller]}}

  def handle_call({:unregister_controller, controller}, _from, state),
    do: {:reply, :ok, %{state | controllers: state.controllers -- [controller]}}

  def handle_call(:connected?, _from, state), do: {:reply, state.connected, state}

  def handle_call(:info, _from, state),
    do: {:reply, %{nick: state.nick, version: state.version, cursor: state.cursor}, state}

  @impl true
  def handle_info({:enet_connected, conn}, %{conn: conn} = state) do
    :ok = state.transport.send(conn, 0, Slippstream.connect_request(), :reliable)

    if state.connect_from do
      GenServer.reply(state.connect_from, :ok)
    end

    if state.reconnecting? do
      Logger.warning("Melee.Console reconnected after #{state.attempt} attempt(s)")
    end

    {:noreply,
     %{
       state
       | connect_from: nil,
         reconnecting?: false,
         attempt: 0,
         reconnect_timer: cancel_timer(state.reconnect_timer)
     }}
  end

  def handle_info({:enet_packet, conn, _channel, data}, %{conn: conn} = state) do
    state =
      case Slippstream.decode(data) do
        {:ok, message} -> handle_message(message, state)
        # Zero-length packets arrive at game end; other garbage is skipped.
        {:error, _} -> state
      end

    {:noreply, maybe_reply_step(state)}
  end

  def handle_info({:enet_disconnected, conn, reason}, %{conn: conn} = state) do
    # Reconnect never covers a failed *initial* connect: `connect/2` owns
    # that outcome and reports it to its caller.
    if state.reconnect == nil or state.connect_from != nil do
      {:noreply, latch(state, reason)}
    else
      {:noreply, state |> reset_stream() |> schedule_reconnect(reason)}
    end
  end

  def handle_info({:reconnect, attempt}, %{attempt: attempt, reconnecting?: true} = state) do
    case state.transport.connect(state.address, state.port, self(), state.transport_opts) do
      {:ok, conn} ->
        timer =
          Process.send_after(
            self(),
            {:reconnect_timeout, attempt},
            state.reconnect.connect_timeout
          )

        {:noreply, %{state | conn: conn, reconnect_timer: timer}}

      {:error, reason} ->
        {:noreply, schedule_reconnect(state, reason)}
    end
  end

  def handle_info(
        {:reconnect_timeout, attempt},
        %{attempt: attempt, reconnecting?: true} = state
      ),
      do: {:noreply, schedule_reconnect(state, :connect_timeout)}

  def handle_info(:poll_timeout, %{step_from: from} = state) when from != nil do
    GenServer.reply(from, nil)
    {:noreply, %{state | step_from: nil, poll_timer: nil}}
  end

  def handle_info(:poll_timeout, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  ## Disconnect / reconnect

  # Terminal disconnect: libmelee's `EnetDisconnected`. Every later step
  # answers `{:error, :enet_disconnected}`.
  @spec latch(State.t(), term()) :: State.t()
  defp latch(state, reason) do
    if state.connect_from,
      do: GenServer.reply(state.connect_from, {:error, {:enet_disconnected, reason}})

    if state.step_from, do: GenServer.reply(state.step_from, {:error, :enet_disconnected})

    %{
      state
      | disconnected: true,
        reconnecting?: false,
        connect_from: nil,
        step_from: nil,
        poll_timer: cancel_timer(state.poll_timer),
        reconnect_timer: cancel_timer(state.reconnect_timer)
    }
  end

  # A reconnect yields a NEW game stream: a parser carrying the old
  # payload-size table, a half-read frame or a stale frame number would
  # misparse it. Queued frames belong to the dead stream too.
  @spec reset_stream(State.t()) :: State.t()
  defp reset_stream(state) do
    %{
      state
      | conn: nil,
        parser: Events.new(state.parser_opts),
        frames: :queue.new(),
        connected: false,
        nick: "",
        version: "",
        cursor: 0
    }
  end

  @spec schedule_reconnect(State.t(), term()) :: State.t()
  defp schedule_reconnect(state, reason) do
    state = %{state | reconnect_timer: cancel_timer(state.reconnect_timer)}
    attempt = state.attempt + 1

    if attempt > state.reconnect.attempts do
      Logger.warning("Melee.Console giving up after #{state.attempt} reconnect attempt(s)")
      latch(state, reason)
    else
      delay = backoff_ms(state.reconnect, attempt)

      Logger.warning(
        "Melee.Console disconnected (#{inspect(reason)}); reconnect attempt " <>
          "#{attempt}/#{state.reconnect.attempts} in #{delay}ms"
      )

      timer = Process.send_after(self(), {:reconnect, attempt}, delay)
      %{state | reconnecting?: true, attempt: attempt, reconnect_timer: timer}
    end
  end

  @doc """
  Capped exponential backoff for reconnect attempt `n` (1-based).

  ## Examples

      iex> policy = %Melee.Console.Reconnect{backoff_ms: 1_000, max_backoff_ms: 5_000}
      iex> Enum.map(1..5, &Melee.Console.backoff_ms(policy, &1))
      [1000, 2000, 4000, 5000, 5000]
  """
  @spec backoff_ms(Reconnect.t(), pos_integer()) :: pos_integer()
  def backoff_ms(%Reconnect{} = policy, attempt) when attempt >= 1,
    do: min(policy.backoff_ms * 2 ** (attempt - 1), policy.max_backoff_ms)

  ## Message handling

  defp handle_message({:connect_reply, %{nick: nick, version: version, cursor: cursor}}, state),
    do: %{state | connected: true, nick: nick, version: version, cursor: cursor}

  defp handle_message({:game_event, <<>>}, state), do: state

  defp handle_message({:game_event, payload}, state),
    do: drain_events(state, payload)

  defp handle_message({:menu_event, <<>>}, state), do: state

  defp handle_message({:menu_event, payload}, state) do
    {:frame_complete, gamestate, parser} = Events.handle_menu_event(state.parser, payload)
    enqueue_frame(%{state | parser: parser}, gamestate)
  end

  defp handle_message(:frame_end, state), do: state
  defp handle_message({:unknown, _msg}, state), do: state

  # Run the event parser to exhaustion over new data + buffered pending.
  defp drain_events(state, payload) do
    case Events.handle_game_event(state.parser, payload) do
      {:frame_complete, gamestate, parser} ->
        state = %{state | parser: parser} |> after_parse() |> enqueue_frame(gamestate)
        if parser.pending == <<>>, do: state, else: drain_events(state, <<>>)

      {:continue, parser} ->
        after_parse(%{state | parser: parser})

      {:rollback, parser} ->
        # Skipped rollback frame: in blocking-input mode the game is
        # waiting on controller input for the re-simulated frame.
        state = after_parse(%{state | parser: parser})
        state = if state.blocking_input, do: flush_controllers(state), else: state
        if parser.pending == <<>>, do: state, else: drain_events(state, <<>>)

      {:game_end, parser} ->
        # Not terminal: menu events follow. Remaining bytes were dropped
        # (post-game data), matching libmelee.
        after_parse(%{state | parser: parser})

      {:error, _reason, parser} ->
        after_parse(%{state | parser: parser})
    end
  end

  # GAME_START: give the game empty input for frame one (characters are
  # not actionable anyway) — mirrors libmelee's release_all + flush.
  defp after_parse(%{parser: %{game_started: true} = parser} = state) do
    state =
      drop_dead_controllers(state, fn controller ->
        Controller.release_all(controller)
        Controller.flush(controller)
      end)

    %{state | parser: Events.clear_game_started(parser)}
  end

  defp after_parse(state), do: state

  ## Frame queue / step bookkeeping

  defp enqueue_frame(state, gamestate),
    do: %{state | frames: :queue.in(gamestate, state.frames)}

  defp pop_frame(state) do
    case :queue.out(state.frames) do
      {{:value, frame}, frames} -> {frame, %{state | frames: frames}}
      {:empty, _} -> nil
    end
  end

  defp maybe_reply_step(%{step_from: nil} = state), do: state

  defp maybe_reply_step(%{step_from: from} = state) do
    case pop_frame(state) do
      {frame, state} ->
        GenServer.reply(from, {:ok, frame})
        %{state | step_from: nil, poll_timer: cancel_timer(state.poll_timer)}

      nil ->
        state
    end
  end

  defp flush_controllers(state), do: drop_dead_controllers(state, &Controller.flush/1)

  # A controller is a separate process; if it died (a supervisor such as
  # `Melee.Session` will restart and re-register it) the console must not
  # die with it, so a `:noproc`/`:normal` exit just drops it from the list.
  @spec drop_dead_controllers(State.t(), (GenServer.server() -> any())) :: State.t()
  defp drop_dead_controllers(state, fun) do
    dead =
      Enum.reject(state.controllers, fn controller ->
        try do
          fun.(controller)
          true
        catch
          :exit, {reason, _call} when reason in [:noproc, :normal] -> false
          :exit, :noproc -> false
        end
      end)

    if dead == [], do: state, else: %{state | controllers: state.controllers -- dead}
  end

  defp cancel_timer(nil), do: nil

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    nil
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn && not state.disconnected, do: state.transport.disconnect(state.conn)
    :ok
  end
end
