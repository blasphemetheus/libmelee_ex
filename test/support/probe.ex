defmodule Melee.Probe do
  @moduledoc """
  A live driver for exploring Melee's menus against a real Dolphin.

  Menu mechanics that the gamestate does not expose — where the tag list
  sits, which cursor coordinates a button box responds to, whether START
  or A confirms a screen — can only be found by driving the real game and
  looking at it. Doing that by hand means re-writing the same frame loop
  every time: step the console, tilt the stick, step again, check whether
  anything happened. `Melee.Probe` is that loop, once.

  The rule that makes it work: *every* operation pumps frames. Dolphin
  only advances when the console is stepped, so an action that does not
  step (`Controller.tilt_analog/4` on its own, say) does nothing at all.
  Each function here drives the console until its goal is met.

  ## Shape of a session

      probe =
        Melee.Probe.start!(
          path: "~/.local/share/slippi/netplay/Slippi_Online-x86_64.AppImage",
          iso_path: "/home/me/isos/melee.iso",
          home: "/home/me/.config/SlippiOnline-probe",
          ports: [1]
        )

      probe
      |> Melee.Probe.navigate!(character: 0x01, stage: 0x19)
      |> Melee.Probe.goto!(-23.7, -18.62)
      |> Melee.Probe.tap!(:a)
      |> Melee.Probe.trace()

      Melee.Probe.stop(probe)

  Functions raise on timeout rather than returning an error tuple: in a
  probe session a cursor that never arrives is a finding, and it should
  stop the script loudly with the coordinates it got stuck at.

  ## Test-only

  This lives in `test/support`, so it is compiled in `:test` only. Run
  exploration scripts with the test env:

      MIX_ENV=test mix run my_exploration.exs
  """

  alias Melee.{Console, Controller, Dolphin, GameState, MenuHelper}

  require Logger

  @typedoc """
  A live probe session: the Dolphin process, the spectator console, and
  one `Melee.Controller` per driven port.

    * `:dolphin` — the launched instance, or `nil` when attached to one
      that was already running
    * `:controllers` — `%{gc_port => controller pid}`
    * `:port` — the port acted on by default
    * `:gamestate` — the most recent gamestate, `nil` before the first
      step
    * `:frames` — how many times this probe has stepped the console. NOT
      the number of emulated frames: polling hands back the latest
      gamestate, so one step can span several of Melee's frames. Use it
      for pacing (`rem(frames, 30)`), never as a clock — see
      `elapsed_ms/1`.
    * `:started_at` — monotonic milliseconds at `start!/1`
    * `:helpers` — a `Melee.MenuHelper` per driven port, so a bot on one
      port and a CPU on another can be navigated in the same frame loop
    * `:trace?` — log every scene transition
  """
  @type t :: %__MODULE__{
          dolphin: Dolphin.t() | nil,
          console: GenServer.server(),
          controllers: %{pos_integer() => GenServer.server()},
          port: pos_integer(),
          gamestate: GameState.t() | nil,
          frames: non_neg_integer(),
          started_at: integer(),
          helpers: %{pos_integer() => MenuHelper.t()},
          trace?: boolean(),
          last_scene: term()
        }

  @enforce_keys [:console, :controllers, :port]
  defstruct dolphin: nil,
            console: nil,
            controllers: %{},
            port: 1,
            gamestate: nil,
            frames: 0,
            started_at: 0,
            helpers: %{},
            trace?: false,
            last_scene: nil

  # A menu cursor moves about 1.2 units a frame at full tilt and
  # accelerates while the stick is held, so a full tilt overshoots any
  # small target. Inside @fine units we ease off to @fine_tilt, which
  # creeps at roughly 0.2 units a frame. Mirrors the approach
  # `Melee.MenuHelper` uses for the nametag flow; kept separate because
  # the probe wants to aim anywhere, not just at known targets.
  @fine 3.0
  @fine_tilt 0.22

  @default_tolerance 0.35
  @default_timeout_frames 600
  @default_slippi_port 51_441

  # Melee.Enums.ControllerStatus wire value for a CPU-controlled port.
  @controller_cpu 1

  ## ------------------------------------------------------------------
  ## Lifecycle
  ## ------------------------------------------------------------------

  @doc """
  Launch Dolphin, connect a console and a controller per port, and
  return a probe ready to step.

  Options are passed through to `Melee.Dolphin.launch/1`, plus:

    * `:ports` — GC ports to drive (default `[1]`); the first is the
      default subject of `goto!/4` and friends
    * `:console` — extra `Melee.Console.start_link/1` options (e.g.
      `transport: Melee.Transport.EnetNif`)
    * `:slippi_port` — spectator port (default `#{@default_slippi_port}`)
    * `:trace` — log scene transitions as they happen (default `false`)
    * `:boot_timeout` — ms to wait for the console (default `60_000`)

  Raises if Dolphin or the console fails to come up.
  """
  @spec start!(keyword()) :: t()
  def start!(opts) do
    ports = Keyword.get(opts, :ports, [1])
    slippi_port = Keyword.get(opts, :slippi_port, @default_slippi_port)
    boot_timeout = Keyword.get(opts, :boot_timeout, 60_000)
    {console_opts, opts} = Keyword.pop(opts, :console, [])

    launch_opts =
      opts
      |> Keyword.drop([:ports, :trace, :boot_timeout])
      |> Keyword.put(:slippi_port, slippi_port)
      |> Keyword.put(:controller_ports, ports)

    {:ok, dolphin} = Dolphin.launch(launch_opts)

    {:ok, console} =
      Console.start_link(
        [port: slippi_port, polling_mode: true, polling_timeout: 100] ++ console_opts
      )

    :ok = await_console(console, boot_timeout)

    controllers =
      Map.new(ports, fn gc_port ->
        {:ok, controller} = Controller.start_link(pipe_path: Dolphin.pipes_path(dolphin, gc_port))
        :ok = Controller.connect(controller, boot_timeout)
        :ok = Console.register_controller(console, controller)
        {gc_port, controller}
      end)

    %__MODULE__{
      dolphin: dolphin,
      console: console,
      controllers: controllers,
      port: hd(ports),
      started_at: System.monotonic_time(:millisecond),
      helpers: Map.new(ports, &{&1, MenuHelper.new()}),
      trace?: Keyword.get(opts, :trace, false)
    }
  end

  @doc """
  Milliseconds since `start!/1`.

  The honest "did this really drive the game" measure. `:frames` counts
  console steps, which polling can coalesce, so a run that booted Melee
  and walked the menus may report only a few hundred of them.
  """
  @spec elapsed_ms(t()) :: non_neg_integer()
  def elapsed_ms(%__MODULE__{started_at: started_at}) do
    System.monotonic_time(:millisecond) - started_at
  end

  # Dolphin needs a moment before the spectator socket accepts us, so
  # retry the connect rather than failing on the first refusal.
  defp await_console(console, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_console(console, deadline)
  end

  defp do_await_console(console, deadline) do
    case Console.connect(console, 5_000) do
      :ok ->
        :ok

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1_000)
          do_await_console(console, deadline)
        else
          raise "probe: console never connected (#{inspect(reason)})"
        end
    end
  end

  @doc """
  Shut the session down, stopping Dolphin if the probe launched it.

  Every step is crash-tolerant: after a controller dies (an `:epipe`
  when Dolphin stops reading its fifo, say) the release calls raise, and
  a `stop/1` that gave up there would leak the emulator. A leaked
  windowed Dolphin then squats on the probe's spectator port and
  controller fifos, poisoning every later run with the same home
  (observed live: recurring instant `:epipe`s until the zombie was
  killed by hand).
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = probe) do
    Enum.each(probe.controllers, fn {_port, controller} ->
      safe(fn -> Controller.release_all(controller) end)
    end)

    safe(fn -> Console.stop(probe.console) end)
    if probe.dolphin, do: safe(fn -> Dolphin.stop(probe.dolphin) end)
    :ok
  end

  defp safe(fun) do
    fun.()
  catch
    _kind, _reason -> :ok
  end

  ## ------------------------------------------------------------------
  ## Reading the live state
  ## ------------------------------------------------------------------

  @doc "The most recent gamestate, or `nil` before the first step."
  @spec gamestate(t()) :: GameState.t() | nil
  def gamestate(%__MODULE__{gamestate: gamestate}), do: gamestate

  @doc """
  The menu cursor for `port` (default: the probe's port) as `{x, y}`, or
  `nil` when that port has no player in the current gamestate.
  """
  @spec cursor(t(), pos_integer() | nil) :: {float(), float()} | nil
  def cursor(%__MODULE__{} = probe, port \\ nil) do
    port = port || probe.port

    with %GameState{} = gamestate <- probe.gamestate,
         {:ok, player} <- Map.fetch(gamestate.players, port) do
      {player.cursor.x, player.cursor.y}
    else
      _ -> nil
    end
  end

  @doc """
  A one-line summary of where the game currently is. The thing you want
  in a log when a menu does something surprising.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{gamestate: nil}), do: "[probe] no gamestate yet"

  def describe(%__MODULE__{gamestate: gamestate}) do
    cursors =
      gamestate.players
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(" ", fn {port, player} ->
        "p#{port}=(#{round2(player.cursor.x)},#{round2(player.cursor.y)})" <>
          " char=#{player.character} coin=#{player.coin_down}"
      end)

    "[probe] f=#{gamestate.frame} menu=#{gamestate.menu_state} " <>
      "sub=#{gamestate.submenu} sel=#{gamestate.menu_selection} " <>
      "ready=#{gamestate.ready_to_start} #{cursors}"
  end

  @doc "Log `describe/1` at info level. Returns the probe unchanged."
  @spec trace(t()) :: t()
  def trace(%__MODULE__{} = probe) do
    Logger.info(describe(probe))
    probe
  end

  defp round2(float), do: Float.round(float * 1.0, 2)

  ## ------------------------------------------------------------------
  ## Stepping
  ## ------------------------------------------------------------------

  @doc """
  Advance exactly one frame, refreshing the probe's gamestate.

  A `nil` from the console means "no frame ready yet"; we keep asking,
  because a probe that silently skipped frames would make every
  frame-counted measurement wrong.
  """
  @spec step!(t()) :: t()
  def step!(%__MODULE__{} = probe) do
    case Console.step(probe.console, 30_000) do
      {:ok, gamestate} ->
        probe
        |> Map.put(:gamestate, gamestate)
        |> Map.update!(:frames, &(&1 + 1))
        |> maybe_trace()

      nil ->
        step!(probe)

      other ->
        raise "probe: console step failed: #{inspect(other)}"
    end
  end

  defp maybe_trace(%__MODULE__{trace?: false} = probe), do: probe

  defp maybe_trace(%__MODULE__{gamestate: gamestate} = probe) do
    scene = {gamestate.menu_state, gamestate.submenu, gamestate.menu_selection}

    if scene != probe.last_scene do
      Logger.info(describe(probe))
    end

    %{probe | last_scene: scene}
  end

  @doc """
  Step `count` frames, running `fun` (a `t -> t`) before each one. The
  building block every other action is written in terms of.
  """
  @spec advance!(t(), non_neg_integer(), (t() -> t())) :: t()
  def advance!(%__MODULE__{} = probe, count, fun \\ &Function.identity/1) do
    Enum.reduce(1..count//1, probe, fn _i, probe -> probe |> fun.() |> step!() end)
  end

  @doc """
  Step frames, running `fun` before each, until `done?` says we are
  where we want to be.

  `done?` receives the whole probe, not just the gamestate: what you are
  waiting for is often a fact about the driver rather than the screen
  ("the nametag flow finished"), and a predicate that could only see the
  gamestate could not express it.

  Options:

    * `:timeout_frames` — frames to allow (default `#{@default_timeout_frames}`)
    * `:describe` — what we were waiting for, used in the raised message
  """
  @spec until!(t(), (t() -> boolean()), (t() -> t()), keyword()) :: t()
  def until!(%__MODULE__{} = probe, done?, fun \\ &Function.identity/1, opts \\ []) do
    limit = Keyword.get(opts, :timeout_frames, @default_timeout_frames)
    what = Keyword.get(opts, :describe, "condition")

    probe =
      Enum.reduce_while(1..limit//1, probe, fn _i, probe ->
        if reached?(probe, done?) do
          {:halt, probe}
        else
          {:cont, probe |> fun.() |> step!()}
        end
      end)

    if reached?(probe, done?) do
      probe
    else
      raise "probe: timed out after #{limit} frames waiting for #{what}. #{describe(probe)}"
    end
  end

  # A probe with no gamestate has not observed anything yet, so no
  # condition on the live game can be true.
  defp reached?(%__MODULE__{gamestate: nil}, _done?), do: false
  defp reached?(%__MODULE__{} = probe, done?), do: done?.(probe)

  @doc """
  Step frames until `done?` holds, holding the controller neutral.
  """
  @spec wait_until!(t(), (t() -> boolean()), keyword()) :: t()
  def wait_until!(%__MODULE__{} = probe, done?, opts \\ []) do
    until!(probe, done?, &neutral/1, opts)
  end

  @doc """
  Step frames, driving `Melee.MenuHelper` on one or more ports, until
  `done?` holds. Helper state is kept on the probe, so successive calls
  continue the same navigation.

  `helper_opts` is one keyword list of `Melee.MenuHelper.step/4`
  options, a list of them (one per port, all stepped every frame), or a
  function from the probe to either — for options that have to depend on
  the live state.

  ## Driving two ports

  A match cannot start until something occupies a second port, so the
  usual setup is a bot plus a CPU. The two helpers never fight over
  inputs, because each writes its own controller; the one genuinely
  shared decision is *when to start the match*, and that has to be
  gated. Melee raises READY TO FIGHT as soon as two ports are filled —
  well before a CPU level has finished being dragged — so an
  unconditional `autostart: true` starts the match with whatever level
  the slider happened to be at. Gate it with `autostart?/2`:

      Melee.Probe.drive!(
        probe,
        &Melee.Probe.at_menu?(&1, :in_game),
        fn probe ->
          [
            [port: 1, character: fox, stage: fd,
             autostart: Melee.Probe.autostart?(probe, [cpu_opts])],
            cpu_opts
          ]
        end,
        timeout_frames: 12_000
      )

  This is `navigate!/2` with an explicit stopping condition; use it when
  the condition is about the driver rather than the screen
  (`&(Melee.Probe.helper(&1).nametag_done)`, say).
  """
  @spec drive!(
          t(),
          (t() -> boolean()),
          keyword() | [keyword()] | (t() -> keyword() | [keyword()]),
          keyword()
        ) :: t()
  def drive!(%__MODULE__{} = probe, done?, helper_opts, opts \\ []) do
    drive = fn %__MODULE__{} = probe ->
      probe
      |> resolve_opts(helper_opts)
      |> Enum.reduce(probe, &step_helper(&2, &1))
    end

    # MenuHelper needs a gamestate before its first step.
    probe = if probe.gamestate, do: probe, else: step!(probe)

    until!(probe, done?, drive, opts)
  end

  defp resolve_opts(probe, helper_opts) when is_function(helper_opts, 1),
    do: resolve_opts(probe, helper_opts.(probe))

  defp resolve_opts(_probe, helper_opts) do
    if Keyword.keyword?(helper_opts), do: [helper_opts], else: helper_opts
  end

  @doc """
  Should `autostart` be set this frame, given the other ports that have
  to finish configuring first?

  At the character select screen this is false until every port in
  `other_opts` is `port_configured?/2`, so the match cannot start on a
  half-dragged CPU slider. Everywhere else it is true: the gate exists
  to sequence the *start*, and `Melee.MenuHelper` will not navigate the
  stage select at all without `autostart`, so leaving it off past the
  CSS strands the run there.
  """
  @spec autostart?(t(), [keyword()]) :: boolean()
  def autostart?(%__MODULE__{} = probe, other_opts) do
    not at_character_select?(probe) or
      Enum.all?(other_opts, &port_configured?(probe, &1))
  end

  @doc """
  Has the port described by `helper_opts` finished being set up — the
  right character locked in, and the right CPU level and CPU status if a
  level was asked for?

  Deliberately does NOT look at `coin_down`. That field means "the hand
  is currently over this port's coin", not "this port has picked" — and
  a port that has just finished dragging its CPU slider leaves the hand
  down at the slider, so requiring it would never come true. `character`
  keeps reporting the locked-in pick after the hand moves away; it only
  wobbles while a port is merely *hovering* portraits, and for a CPU
  port the level and status checks rule that out.
  """
  @spec port_configured?(t(), keyword()) :: boolean()
  def port_configured?(%__MODULE__{gamestate: nil}, _helper_opts), do: false

  def port_configured?(%__MODULE__{} = probe, helper_opts) do
    port = Keyword.get(helper_opts, :port, probe.port)

    case Map.fetch(probe.gamestate.players, port) do
      {:ok, player} ->
        character_ready? = player.character == Keyword.fetch!(helper_opts, :character)

        cpu_ready? =
          case Keyword.get(helper_opts, :cpu_level, 0) do
            0 -> true
            level -> player.cpu_level == level and player.controller_status == @controller_cpu
          end

        character_ready? and cpu_ready?

      :error ->
        false
    end
  end

  defp step_helper(%__MODULE__{} = probe, helper_opts) do
    port = Keyword.get(helper_opts, :port, probe.port)
    controller = controller!(probe, port)
    helper = Map.get(probe.helpers, port, MenuHelper.new())
    helper = MenuHelper.step(helper, probe.gamestate, controller, helper_opts)

    %{probe | helpers: Map.put(probe.helpers, port, helper)}
  end

  @doc "The `Melee.MenuHelper` state for `port` (default: the probe's port)."
  @spec helper(t(), pos_integer() | nil) :: MenuHelper.t()
  def helper(%__MODULE__{} = probe, port \\ nil) do
    Map.get(probe.helpers, port || probe.port, MenuHelper.new())
  end

  ## ------------------------------------------------------------------
  ## Driving the controller
  ## ------------------------------------------------------------------

  @doc """
  Walk the menu cursor to `{x, y}` and stop there.

  Steers one axis at a time and eases off the stick near the target, so
  it lands inside `:tolerance` instead of oscillating around it. Pass
  `x: nil` to leave the x axis alone — some Melee menus (the CSS tag
  list, for one) pin the cursor's x and only y does anything.

  Options: `:tolerance` (default `#{@default_tolerance}`), `:port`,
  `:timeout_frames`.
  """
  @spec goto!(t(), number() | nil, number(), keyword()) :: t()
  def goto!(%__MODULE__{} = probe, x, y, opts \\ []) do
    port = Keyword.get(opts, :port, probe.port)
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)

    arrived? = fn probe ->
      case Map.fetch(probe.gamestate.players, port) do
        {:ok, player} -> within?(player.cursor, x, y, tolerance)
        :error -> false
      end
    end

    probe =
      until!(
        probe,
        arrived?,
        &steer(&1, port, x, y, tolerance),
        Keyword.put_new(opts, :describe, "cursor to reach {#{inspect(x)}, #{y}}")
      )

    neutral(probe)
  end

  defp within?(cursor, x, y, tolerance) do
    abs(cursor.y - y) <= tolerance and (x == nil or abs(cursor.x - x) <= tolerance)
  end

  defp steer(%__MODULE__{} = probe, port, x, y, tolerance) do
    controller = controller!(probe, port)

    case probe.gamestate && Map.fetch(probe.gamestate.players, port) do
      {:ok, player} ->
        %{x: cursor_x, y: cursor_y} = player.cursor

        cond do
          cursor_y < y - tolerance ->
            Controller.tilt_analog(controller, :main, 0.5, 0.5 + tilt(y - cursor_y))

          cursor_y > y + tolerance ->
            Controller.tilt_analog(controller, :main, 0.5, 0.5 - tilt(cursor_y - y))

          x == nil ->
            Controller.tilt_analog(controller, :main, 0.5, 0.5)

          cursor_x < x - tolerance ->
            Controller.tilt_analog(controller, :main, 0.5 + tilt(x - cursor_x), 0.5)

          cursor_x > x + tolerance ->
            Controller.tilt_analog(controller, :main, 0.5 - tilt(cursor_x - x), 0.5)

          true ->
            Controller.tilt_analog(controller, :main, 0.5, 0.5)
        end

      _ ->
        Controller.release_all(controller)
    end

    probe
  end

  defp tilt(distance) when distance > @fine, do: 0.5
  defp tilt(_distance), do: @fine_tilt

  @doc """
  Press `button`, hold it for a few frames, release, then let the menu
  react — exactly one press as the game sees it.

  Options: `:hold` frames to hold (default `4`), `:settle` frames to wait
  after releasing (default `20`), `:port`.
  """
  @spec tap!(t(), atom(), keyword()) :: t()
  def tap!(%__MODULE__{} = probe, button, opts \\ []) do
    controller = controller!(probe, Keyword.get(opts, :port, probe.port))
    hold = Keyword.get(opts, :hold, 4)
    settle = Keyword.get(opts, :settle, 20)

    probe
    |> advance!(hold, fn probe ->
      Controller.press_button(controller, button)
      probe
    end)
    |> advance!(settle, fn probe ->
      Controller.release_button(controller, button)
      probe
    end)
  end

  @doc """
  Hold the main stick at `{x, y}` (0..1, 0.5 centered) for `frames`, then
  centre it. For poking at a menu whose cursor the gamestate does not
  report, where `goto!/4` has nothing to aim by.
  """
  @spec tilt!(t(), number(), number(), non_neg_integer(), keyword()) :: t()
  def tilt!(%__MODULE__{} = probe, x, y, frames, opts \\ []) do
    controller = controller!(probe, Keyword.get(opts, :port, probe.port))

    probe
    |> advance!(frames, fn probe ->
      Controller.tilt_analog(controller, :main, x, y)
      probe
    end)
    |> neutral()
    |> advance!(2)
  end

  @doc "Release everything on every driven port and step `frames`."
  @spec idle!(t(), non_neg_integer()) :: t()
  def idle!(%__MODULE__{} = probe, frames \\ 1) do
    advance!(probe, frames, &neutral/1)
  end

  defp neutral(%__MODULE__{} = probe) do
    Enum.each(probe.controllers, fn {_port, controller} ->
      Controller.release_all(controller)
    end)

    probe
  end

  defp controller!(%__MODULE__{controllers: controllers}, port) do
    case Map.fetch(controllers, port) do
      {:ok, controller} ->
        controller

      :error ->
        raise ArgumentError,
              "probe: port #{port} is not driven (have #{inspect(Map.keys(controllers))})"
    end
  end

  ## ------------------------------------------------------------------
  ## Menu navigation
  ## ------------------------------------------------------------------

  @doc """
  Hand the controller to `Melee.MenuHelper` until `:until` holds —
  the fast way to get to the screen you actually want to poke at.

  `opts` are `Melee.MenuHelper.step/4` options (`:character` and
  `:stage` are required) plus:

    * `:until` — a `t() -> boolean()`; defaults to "we are at the
      character select screen"
    * `:timeout_frames` — default `3_000`, since booting to the CSS from
      the main menu takes a while

  The helper state persists on the probe, so successive calls continue
  the same navigation rather than starting over.
  """
  @spec navigate!(t(), keyword()) :: t()
  def navigate!(%__MODULE__{} = probe, opts) do
    {until, opts} = Keyword.pop(opts, :until, &at_character_select?/1)
    {timeout, helper_opts} = Keyword.pop(opts, :timeout_frames, 3_000)

    probe
    |> drive!(until, helper_opts,
      timeout_frames: timeout,
      describe: "MenuHelper to reach its target"
    )
    |> neutral()
  end

  @doc "Is the probe at either character select screen?"
  @spec at_character_select?(t()) :: boolean()
  def at_character_select?(%__MODULE__{gamestate: %GameState{menu_state: menu_state}}) do
    menu_state in [
      Melee.Enums.Menu.to_id(:character_select),
      Melee.Enums.Menu.to_id(:slippi_online_css)
    ]
  end

  def at_character_select?(%__MODULE__{}), do: false

  @doc "Is the probe at the named `Melee.Enums.Menu` scene?"
  @spec at_menu?(t(), atom()) :: boolean()
  def at_menu?(%__MODULE__{gamestate: %GameState{} = gamestate}, menu) do
    gamestate.menu_state == Melee.Enums.Menu.to_id(menu)
  end

  def at_menu?(%__MODULE__{}, _menu), do: false

  @doc "Reset the `Melee.MenuHelper` state for `port`."
  @spec reset_helper(t(), pos_integer() | nil) :: t()
  def reset_helper(%__MODULE__{} = probe, port \\ nil) do
    %{probe | helpers: Map.put(probe.helpers, port || probe.port, MenuHelper.new())}
  end
end
