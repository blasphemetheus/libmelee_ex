defmodule Melee.Tech do
  @moduledoc """
  Frame-perfect tech-skill primitives: the building blocks of Melee
  movement, as reactive per-frame routines.

  Melee "tech" is a large, partly character-specific vocabulary —
  wavedashing, L-cancelling, SHFFL'd aerials, dash-dancing, shine
  loops, ledgedashes, pivots, DJC, and on (see the catalog in
  `docs/melee-tech.md`). This module ships the foundation tier:
  routines that read the player's action state each frame and emit the
  exact inputs, timed off each character's jumpsquat.

  ## The shape

  A routine is a small state machine stepped once per frame. The core
  is PURE — `step/2` maps `{tech, player_state}` to
  `{status, tech, commands}` — so every timing decision is unit-testable
  without an emulator; `step/3` additionally applies the commands to a
  `Melee.Controller`:

      tech = Melee.Tech.new(:wavedash, :fox, direction: :left)

      # inside your per-frame loop:
      {status, tech} = Melee.Tech.step(tech, gamestate.players[1], controller)

  `status` is `:cont` while the routine runs and `:done` when it
  completed (continuous routines like `:dash_dance` and `:multishine`
  never finish). Chain routines by switching on `:done`.

  ## Routines

  | routine | opts | what it does |
  | --- | --- | --- |
  | `:short_hop` | — | tap jump shorter than jumpsquat; done when airborne |
  | `:full_hop` | — | hold jump through jumpsquat; done when airborne |
  | `:wavedash` | `direction: :left \\| :right \\| :neutral` | jump, then airdodge diagonally into the ground on the first airborne frame; done at the special landing |
  | `:dash_dance` | `interval: frames` (default 8) | alternate full left/right dashes forever |
  | `:shffl` | `aerial: :nair \\| :fair \\| :bair \\| :uair \\| :dair` | short hop, aerial, fast fall, pulsed L-cancel; done at the (cancelled) aerial landing |
  | `:multishine` | — | Fox/Falco jump-cancelled shine loop, forever |

  ## Timing sources

  Jumpsquat frames are character data (Fox 3, Falco 5, Bowser 8...)
  compiled in from the community-standard NTSC table — the one
  per-character input this tier needs. The L-cancel window is 7 frames
  before landing; `:shffl` covers it by pulsing L on a 6-frame period
  during the falling aerial, which guarantees a press edge inside any
  7-frame window without predicting the landing frame.
  """

  alias Melee.{Controller, Enums, PlayerState}

  @type routine :: :short_hop | :full_hop | :wavedash | :dash_dance | :shffl | :multishine
  @type command ::
          {:press, Controller.button()}
          | {:release, Controller.button()}
          | {:tilt, :main | :c, float(), float()}
          | :release_all
  @type status :: :cont | :done

  @type t :: %__MODULE__{
          routine: routine(),
          character: integer(),
          jumpsquat: pos_integer(),
          opts: keyword(),
          phase: atom(),
          counter: non_neg_integer()
        }

  @enforce_keys [:routine, :character, :jumpsquat]
  defstruct [:routine, :character, :jumpsquat, opts: [], phase: :init, counter: 0, aux: nil]

  # Jumpsquat (knee-bend) frames per character, NTSC 1.02 — community
  # frame data; the multishine test live-verifies Fox's 3 and the
  # movement tests exercise the table through wavedash timing.
  @jumpsquat %{
    bowser: 8,
    cptfalcon: 4,
    dk: 5,
    doc: 4,
    falco: 5,
    fox: 3,
    gameandwatch: 4,
    ganondorf: 6,
    jigglypuff: 5,
    kirby: 3,
    link: 6,
    luigi: 4,
    mario: 4,
    marth: 4,
    mewtwo: 5,
    nana: 3,
    ness: 4,
    peach: 5,
    pichu: 3,
    pikachu: 3,
    popo: 3,
    roy: 5,
    samus: 3,
    sheik: 3,
    yoshi: 5,
    ylink: 4,
    zelda: 6
  }

  # Action ids (Melee.Enums.Action)
  @standing 0x0E
  @turning 0x12
  @dashing 0x14
  @running 0x15
  @knee_bend 0x18
  @landing_special 0x2B
  @shine_ground_start Enums.Action.to_id(:down_b_ground_start)
  @shine_ground Enums.Action.to_id(:down_b_ground)
  @shine_stun Enums.Action.to_id(:down_b_stun)
  @aerial_attacks 0x41..0x45
  @aerial_landings 0x46..0x4A

  @aerial_stick %{
    nair: nil,
    fair: {1.0, 0.5},
    bair: {0.0, 0.5},
    uair: {0.5, 1.0},
    dair: {0.5, 0.0}
  }

  @doc """
  Build a routine for a character (`Melee.Enums.Character` atom or
  internal id).

  ## Examples

      iex> tech = Melee.Tech.new(:wavedash, :fox, direction: :left)
      iex> {tech.jumpsquat, tech.phase}
      {3, :init}

      iex> Melee.Tech.new(:short_hop, :falco).jumpsquat
      5
  """
  @spec new(routine(), atom() | integer(), keyword()) :: t()
  def new(routine, character, opts \\ [])
      when routine in [:short_hop, :full_hop, :wavedash, :dash_dance, :shffl, :multishine] do
    id = if is_atom(character), do: Enums.Character.to_id(character), else: character

    jumpsquat =
      Map.get(@jumpsquat, Enums.Character.from_id(id)) ||
        raise ArgumentError, "no jumpsquat data for character #{inspect(character)}"

    %__MODULE__{routine: routine, character: id, jumpsquat: jumpsquat, opts: opts}
  end

  @doc """
  Advance the routine one frame against the player's current state.
  Pure: returns the commands to apply this frame.

  ## Examples

      iex> tech = Melee.Tech.new(:short_hop, :fox)
      iex> standing = %Melee.PlayerState{action: 0x0E, on_ground: true}
      iex> {:cont, tech, [{:press, :y}]} = Melee.Tech.step(tech, standing)
      iex> {:cont, tech, [{:release, :y}]} =
      ...>   Melee.Tech.step(tech, %{standing | action: 0x18, action_frame: 1})
      iex> {status, _tech, _commands} =
      ...>   Melee.Tech.step(tech, %{standing | on_ground: false, action: 0x1D})
      iex> status
      :done
  """
  @spec step(t(), PlayerState.t()) :: {status(), t(), [command()]}
  def step(%__MODULE__{routine: routine} = tech, %PlayerState{} = player) do
    case routine do
      :short_hop -> hop(tech, player, :short)
      :full_hop -> hop(tech, player, :full)
      :wavedash -> wavedash(tech, player)
      :dash_dance -> dash_dance(tech, player)
      :shffl -> shffl(tech, player)
      :multishine -> multishine(tech, player)
    end
  end

  @doc "Step and apply the commands to a `Melee.Controller`."
  @spec step(t(), PlayerState.t(), GenServer.server()) :: {status(), t()}
  def step(%__MODULE__{} = tech, %PlayerState{} = player, controller) do
    {status, tech, commands} = step(tech, player)
    Enum.each(commands, &apply_command(controller, &1))
    {status, tech}
  end

  defp apply_command(controller, {:press, button}),
    do: Controller.press_button(controller, button)

  defp apply_command(controller, {:release, button}),
    do: Controller.release_button(controller, button)

  defp apply_command(controller, {:tilt, stick, x, y}),
    do: Controller.tilt_analog(controller, stick, x, y)

  defp apply_command(controller, :release_all), do: Controller.release_all(controller)

  ## ------------------------------------------------------------------
  ## Hops
  ## ------------------------------------------------------------------

  # Short hop: the jump button must be RELEASED before jumpsquat ends,
  # so press for exactly one observed frame — legal for every
  # character (minimum jumpsquat is 3). Full hop holds through it.
  defp hop(%{phase: :init} = tech, %{on_ground: true} = _player, _kind),
    do: {:cont, %{tech | phase: :rising}, [{:press, :y}]}

  defp hop(%{phase: :init} = tech, _player, _kind), do: {:cont, tech, []}

  defp hop(%{phase: :rising} = tech, player, kind) do
    cond do
      not player.on_ground ->
        {:done, tech, [{:release, :y}]}

      kind == :short ->
        {:cont, tech, [{:release, :y}]}

      true ->
        {:cont, tech, [{:press, :y}]}
    end
  end

  ## ------------------------------------------------------------------
  ## Wavedash
  ## ------------------------------------------------------------------

  # Jump, then airdodge diagonally into the ground on the FIRST
  # airborne frame. The airdodge press must happen airborne (grounded
  # L is a shield), and blocking-input mode shows every frame exactly
  # once, so "first frame with on_ground false" is the precise trigger.
  defp wavedash(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :jumping}, [{:press, :y}]}

  defp wavedash(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp wavedash(%{phase: :jumping} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      x =
        case Keyword.get(tech.opts, :direction, :neutral) do
          :left -> 0.05
          :right -> 0.95
          :neutral -> 0.5
        end

      # Down-diagonal: steep enough to reach the ground within the
      # airdodge, shallow enough to keep the slide long.
      {:cont, %{tech | phase: :airdodge, counter: 0},
       [{:release, :y}, {:tilt, :main, x, 0.2}, {:press, :l}]}
    end
  end

  defp wavedash(%{phase: :airdodge, counter: c} = tech, player) do
    cond do
      player.action == @landing_special ->
        {:done, tech, [:release_all]}

      c >= 2 ->
        {:cont, %{tech | counter: c + 1}, [{:release, :l}]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  ## ------------------------------------------------------------------
  ## Dash dance
  ## ------------------------------------------------------------------

  # Alternate full-tilt left/right every `interval` frames, CENTERED:
  # open-loop alternation drifts (measured live: an interval-8 dance
  # walked Fox off FD's edge within ~200 frames), so the routine
  # remembers its origin and flips early whenever it strays more than
  # `band` units away while still heading outward. Staying inside the
  # initial-dash window is what makes it a dash dance rather than a
  # run turnaround; the default 8 sits inside every character's window.
  defp dash_dance(%{phase: :init} = tech, player) do
    dash_dance(%{tech | phase: :left, counter: 0, aux: player.position.x}, player)
  end

  defp dash_dance(%{phase: phase, counter: c, aux: origin} = tech, player) do
    interval = Keyword.get(tech.opts, :interval, 8)
    band = Keyword.get(tech.opts, :band, 10.0)
    x_pos = player.position.x

    outward? =
      (phase == :left and x_pos < origin - band) or
        (phase == :right and x_pos > origin + band)

    {phase, c} = if c >= interval or outward?, do: {flip(phase), 0}, else: {phase, c}
    x = if phase == :left, do: 0.0, else: 1.0
    {:cont, %{tech | phase: phase, counter: c + 1}, [{:tilt, :main, x, 0.5}]}
  end

  defp flip(:left), do: :right
  defp flip(:right), do: :left

  ## ------------------------------------------------------------------
  ## SHFFL
  ## ------------------------------------------------------------------

  # Short hop, aerial on the way up, fast fall at the apex, and an
  # L-cancel: L pulsed on a 6-frame period through the falling attack,
  # guaranteeing a press EDGE inside the 7-frame pre-landing window
  # without having to predict the landing frame. Pulses in an aerial
  # attack have no other effect (the character cannot act), and the
  # cancelled landing is the :done signal.
  defp shffl(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :hop}, [{:press, :y}]}

  defp shffl(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp shffl(%{phase: :hop} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      aerial = Keyword.get(tech.opts, :aerial, :nair)

      commands =
        case @aerial_stick[aerial] do
          nil -> [{:release, :y}, {:press, :a}]
          {cx, cy} -> [{:release, :y}, {:tilt, :c, cx, cy}]
        end

      {:cont, %{tech | phase: :attack, counter: 0}, commands}
    end
  end

  defp shffl(%{phase: :attack} = tech, player) do
    cond do
      player.action in @aerial_landings or
          (player.on_ground and player.action not in @aerial_attacks) ->
        {:done, tech, [:release_all]}

      player.speed_y_self < 0 ->
        # Falling: fast fall once, then run the L pulse.
        {:cont, %{tech | phase: :fall, counter: 0},
         [{:release, :a}, {:tilt, :c, 0.5, 0.5}, {:tilt, :main, 0.5, 0.0}]}

      true ->
        {:cont, tech, [{:release, :a}, {:tilt, :c, 0.5, 0.5}]}
    end
  end

  defp shffl(%{phase: :fall, counter: c} = tech, player) do
    cond do
      player.action in @aerial_landings or player.on_ground ->
        {:done, tech, [:release_all]}

      # l_cancel: false is the experiment's control arm — identical
      # routine, no L pulse — so tests can prove the cancel by lag
      # comparison rather than assume it.
      not Keyword.get(tech.opts, :l_cancel, true) ->
        {:cont, %{tech | counter: c + 1}, []}

      rem(c, 6) == 0 ->
        {:cont, %{tech | counter: c + 1}, [{:press, :l}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :l}]}
    end
  end

  ## ------------------------------------------------------------------
  ## Multishine
  ## ------------------------------------------------------------------

  # The canonical Fox/Falco jump-cancelled shine loop (the library's
  # oldest frame-perfect proof, promoted from the multishine example):
  # shine from standing; re-shine on jumpsquat frame 3; jump out of
  # the shine once it is cancellable (frame >= 3, grounded).
  defp multishine(tech, p) do
    commands =
      cond do
        p.action == @standing ->
          [{:press, :b}, {:tilt, :main, 0.5, 0.0}]

        p.action == @knee_bend and p.action_frame == 3 ->
          [{:press, :b}, {:tilt, :main, 0.5, 0.0}]

        p.action == @knee_bend ->
          [{:release, :b}]

        p.action in [@shine_ground_start, @shine_stun] and p.action_frame >= 3 and p.on_ground ->
          [{:release, :b}, {:press, :y}]

        p.action == @shine_ground ->
          [{:press, :y}]

        true ->
          [:release_all]
      end

    {:cont, tech, commands}
  end

  @doc false
  def __actions__,
    do: %{
      standing: @standing,
      turning: @turning,
      dashing: @dashing,
      running: @running,
      knee_bend: @knee_bend,
      landing_special: @landing_special
    }
end
