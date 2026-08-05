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

  ## Example

      {:ok, console} = Melee.Console.start_link([])
      {:ok, controller} = Melee.Controller.start_link(pipe_path: pipe)
      :ok = Melee.Console.connect(console)
      :ok = Melee.Console.register_controller(console, controller)
      :ok = Melee.Controller.connect(controller)

      {:ok, gamestate} = Melee.Console.step(console)
  """

  use GenServer

  alias Melee.{Controller, Events, GameState, Slippstream}

  @type step_result :: {:ok, GameState.t()} | nil | {:error, :enet_disconnected}

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
              polling_timeout: 0
  end

  @impl true
  def init(opts) do
    state = %State{
      transport: Keyword.get(opts, :transport, Melee.Transport.EnetNif),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      address: Keyword.get(opts, :address, "127.0.0.1"),
      port: Keyword.get(opts, :port, 51_441),
      parser: Events.new(skip_rollback_frames: Keyword.get(opts, :skip_rollback_frames, true)),
      blocking_input: Keyword.get(opts, :blocking_input, true),
      polling_mode: Keyword.get(opts, :polling_mode, false),
      polling_timeout: Keyword.get(opts, :polling_timeout, 0)
    }

    {:ok, state}
  end

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

  def handle_call(:connected?, _from, state), do: {:reply, state.connected, state}

  def handle_call(:info, _from, state),
    do: {:reply, %{nick: state.nick, version: state.version, cursor: state.cursor}, state}

  @impl true
  def handle_info({:enet_connected, conn}, %{conn: conn} = state) do
    :ok = state.transport.send(conn, 0, Slippstream.connect_request(), :reliable)

    if state.connect_from do
      GenServer.reply(state.connect_from, :ok)
    end

    {:noreply, %{state | connect_from: nil}}
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
    state = %{state | disconnected: true}

    if state.connect_from,
      do: GenServer.reply(state.connect_from, {:error, {:enet_disconnected, reason}})

    if state.step_from, do: GenServer.reply(state.step_from, {:error, :enet_disconnected})

    {:noreply,
     %{state | connect_from: nil, step_from: nil, poll_timer: cancel_timer(state.poll_timer)}}
  end

  def handle_info(:poll_timeout, %{step_from: from} = state) when from != nil do
    GenServer.reply(from, nil)
    {:noreply, %{state | step_from: nil, poll_timer: nil}}
  end

  def handle_info(:poll_timeout, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

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
    Enum.each(state.controllers, fn controller ->
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

  defp flush_controllers(state) do
    Enum.each(state.controllers, &Controller.flush/1)
    state
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
