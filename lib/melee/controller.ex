defmodule Melee.Controller do
  @moduledoc """
  A virtual GameCube controller, driven over Dolphin's named-pipe input
  mechanism.

  Mirrors libmelee's `Controller`. Commands are newline-terminated text
  written to a fifo that Dolphin reads (`PRESS A`, `SET MAIN 0.5 0.5`,
  `SET L 0.7`, `FLUSH`). Button presses are effectively write-through —
  Dolphin applies everything buffered in the pipe when it sees `FLUSH`.

  Start one per controller port, then `connect/2` once Dolphin is
  running. Note that opening a fifo's write end blocks until Dolphin has
  opened the read end, exactly like Python libmelee's `connect()`.

  By default analog inputs are quantized (`fix_analog_inputs`) so that
  the values you send match what `Melee.Console` reports back on the
  next frame, modulo deadzones.
  """

  use GenServer

  alias Melee.ControllerState
  alias Melee.Enums.Button

  @type button :: Melee.ControllerState.button() | :main | :c

  ## Analog quantization (controller.py fix_analog_stick / fix_analog_trigger)

  @doc """
  Quantize an analog stick axis so Dolphin's processed value round-trips.

  Melee reads sticks as raw values in [-80, 80]; this maps `x` in [0, 1]
  onto that grid, nudged just above the rounding threshold.

  ## Examples (values match Python libmelee exactly)

      iex> Melee.Controller.fix_analog_stick(0.5)
      0.5003937007874015

      iex> Melee.Controller.fix_analog_stick(1.0)
      0.8153543307086614

      iex> Melee.Controller.fix_analog_stick(0.0)
      0.1854330708661417
  """
  @spec fix_analog_stick(float()) :: float()
  def fix_analog_stick(x) do
    raw = round_half_even((x - 0.5) * 160)
    (raw + 0.1) / (127 * 2) + 0.5
  end

  @doc """
  Quantize an analog trigger value (raw range [0, 140]).

  ## Examples (values match Python libmelee exactly)

      iex> Melee.Controller.fix_analog_trigger(0.0)
      0.0003921568627450981

      iex> Melee.Controller.fix_analog_trigger(1.0)
      0.5494117647058824
  """
  @spec fix_analog_trigger(float()) :: float()
  def fix_analog_trigger(x) do
    raw = round_half_even(x * 140)
    (raw + 0.1) / 255
  end

  # Python's round() is banker's rounding (half to even); Elixir's rounds
  # half away from zero. Faithful port so quantized values match exactly.
  defp round_half_even(x) do
    floor_x = floor(x)

    case x - floor_x do
      0.5 -> if rem(floor_x, 2) == 0, do: floor_x, else: floor_x + 1
      frac when frac < 0.5 -> floor_x
      _ -> floor_x + 1
    end
  end

  ## Client API

  @doc """
  Start a controller for the given pipe path.

  Options:

    * `:pipe_path` (required) — the fifo path, e.g. from
      `Melee.DolphinConfig.pipes_path/2`
    * `:fix_analog_inputs` (default `true`)
    * `:name` — optional GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc """
  Open the pipe to Dolphin. Blocks until Dolphin opens the read end.
  """
  @spec connect(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def connect(controller, timeout \\ :infinity),
    do: GenServer.call(controller, :connect, timeout)

  @doc "Press a single button (no effect if already pressed)."
  @spec press_button(GenServer.server(), ControllerState.button()) :: :ok
  def press_button(controller, button), do: GenServer.cast(controller, {:press, button})

  @doc "Release a single button (no effect if already released)."
  @spec release_button(GenServer.server(), ControllerState.button()) :: :ok
  def release_button(controller, button), do: GenServer.cast(controller, {:release, button})

  @doc """
  Press an analog shoulder (`:l` or `:r`) to `amount` in [0, 1].

  The digital L/R press is separate (`press_button/2`); a fully pressed
  analog shoulder does not trigger the digital click.
  """
  @spec press_shoulder(GenServer.server(), :l | :r, float()) :: :ok
  def press_shoulder(controller, button, amount) when button in [:l, :r],
    do: GenServer.cast(controller, {:shoulder, button, amount})

  @doc """
  Tilt an analog stick (`:main` or `:c`) to `(x, y)`, each in [0, 1]
  with 0.5 neutral.
  """
  @spec tilt_analog(GenServer.server(), :main | :c, float(), float()) :: :ok
  def tilt_analog(controller, stick, x, y) when stick in [:main, :c],
    do: GenServer.cast(controller, {:tilt, stick, x, y})

  @doc "Tilt a stick using [-1, 1] coordinates with 0 neutral."
  @spec tilt_analog_unit(GenServer.server(), :main | :c, float(), float()) :: :ok
  def tilt_analog_unit(controller, stick, x, y),
    do: tilt_analog(controller, stick, (x + 1) / 2, (y + 1) / 2)

  @doc "Reset to a resting state: all buttons up, sticks centered, shoulders released."
  @spec release_all(GenServer.server()) :: :ok
  def release_all(controller), do: GenServer.cast(controller, :release_all)

  @doc """
  Simple one-call press: tilt the main stick to `(x, y)`, release the
  shoulders, press `button` (or nil), and release every other button.
  Don't call twice in the same frame.
  """
  @spec simple_press(GenServer.server(), float(), float(), ControllerState.button() | nil) :: :ok
  def simple_press(controller, x, y, button),
    do: GenServer.cast(controller, {:simple_press, x, y, button})

  @doc "Commit this frame's queued inputs (writes `FLUSH`)."
  @spec flush(GenServer.server()) :: :ok
  def flush(controller), do: GenServer.call(controller, :flush)

  @doc "The controller state as of the last `flush/1`."
  @spec prev(GenServer.server()) :: ControllerState.t()
  def prev(controller), do: GenServer.call(controller, :prev)

  @doc "The controller state including presses since the last `flush/1`."
  @spec current(GenServer.server()) :: ControllerState.t()
  def current(controller), do: GenServer.call(controller, :current)

  @doc "Close the pipe and stop the controller."
  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(controller), do: GenServer.stop(controller, :normal)

  ## GenServer implementation

  defmodule State do
    @moduledoc false
    defstruct pipe_path: nil,
              device: nil,
              fix_analog_inputs: true,
              current: %Melee.ControllerState{},
              prev: %Melee.ControllerState{}
  end

  @impl true
  def init(opts) do
    state = %State{
      pipe_path: Keyword.fetch!(opts, :pipe_path),
      fix_analog_inputs: Keyword.get(opts, :fix_analog_inputs, true)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case File.open(state.pipe_path, [:write, :raw]) do
      {:ok, device} -> {:reply, :ok, %{state | device: device}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:flush, _from, state) do
    write(state, "FLUSH\n")
    {:reply, :ok, %{state | prev: state.current}}
  end

  def handle_call(:prev, _from, state), do: {:reply, state.prev, state}
  def handle_call(:current, _from, state), do: {:reply, state.current, state}

  @impl true
  def handle_cast({:press, button}, state) do
    write(state, "PRESS #{Button.to_command_string(button)}\n")
    {:noreply, put_button(state, button, true)}
  end

  def handle_cast({:release, button}, state) do
    write(state, "RELEASE #{Button.to_command_string(button)}\n")
    {:noreply, put_button(state, button, false)}
  end

  def handle_cast({:shoulder, button, amount}, state) do
    wire = if state.fix_analog_inputs, do: fix_analog_trigger(amount), else: amount
    write(state, "SET #{Button.to_command_string(button)} #{fmt(wire)}\n")

    current =
      case button do
        :l -> %{state.current | l_shoulder: amount}
        :r -> %{state.current | r_shoulder: amount}
      end

    {:noreply, %{state | current: current}}
  end

  def handle_cast({:tilt, stick, x, y}, state) do
    {wx, wy} =
      if state.fix_analog_inputs,
        do: {fix_analog_stick(x), fix_analog_stick(y)},
        else: {x, y}

    write(state, "SET #{Button.to_command_string(stick)} #{fmt(wx)} #{fmt(wy)}\n")

    current =
      case stick do
        :main -> %{state.current | main_stick: {wx, wy}}
        :c -> %{state.current | c_stick: {wx, wy}}
      end

    {:noreply, %{state | current: current}}
  end

  def handle_cast(:release_all, state) do
    commands =
      Enum.map_join(ControllerState.buttons(), "", fn b ->
        "RELEASE #{Button.to_command_string(b)}\n"
      end) <>
        "SET MAIN .5 .5\nSET C .5 .5\nSET L 0\nSET R 0\n"

    write(state, commands)
    {:noreply, %{state | current: ControllerState.neutral()}}
  end

  def handle_cast({:simple_press, x, y, button}, state) do
    state = cast_self(state, {:tilt, :main, x, y})
    state = cast_self(state, {:shoulder, :l, 0.0})
    state = cast_self(state, {:shoulder, :r, 0.0})

    Enum.reduce(ControllerState.buttons(), state, fn b, state ->
      cast_self(state, if(b == button, do: {:press, b}, else: {:release, b}))
    end)
    |> then(&{:noreply, &1})
  end

  @impl true
  def terminate(_reason, state) do
    if state.device, do: File.close(state.device)
    :ok
  end

  ## Internals

  defp cast_self(state, msg) do
    {:noreply, state} = handle_cast(msg, state)
    state
  end

  defp put_button(state, button, value) do
    %{state | current: %{state.current | button: Map.put(state.current.button, button, value)}}
  end

  # Not yet connected: state changes still apply, writes are dropped —
  # mirroring Python's `if not self.pipe: return`.
  defp write(%State{device: nil}, _data), do: :ok
  defp write(%State{device: device}, data), do: IO.binwrite(device, data)

  # Python str(float) and Elixir Float.to_string both print the shortest
  # round-trip representation, so wire output matches libmelee exactly.
  defp fmt(value) when is_float(value), do: Float.to_string(value)
  defp fmt(value) when is_integer(value), do: Integer.to_string(value)
end
