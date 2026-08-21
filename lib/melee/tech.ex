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
  | `:shffl` | `aerial: :nair \\| :fair \\| :bair \\| :uair \\| :dair`, `l_cancel: false` for the control arm | short hop, aerial, fast fall, pulsed L-cancel; done at the (cancelled) aerial landing |
  | `:multishine` | — | Fox/Falco jump-cancelled shine loop, forever |
  | `:fast_fall` | — | one down-tap at the falling airborne moment |
  | `:waveland` | `direction:` | the wavedash's airdodge half from the air |
  | `:pivot` | `direction:`, `dash_frames:` | dash, one-frame opposite flick, standing turnaround |
  | `:tech` | `direction: :in_place \\| :left \\| :right`, `height:` | ONE L press near the ground from tumble (never pulsed — early = 40f lockout) |
  | `:ledgedash` | `direction:` (where the stage is), `dodge_height:` | release, double-jump above the lip, waveland on with the ledge invincibility |
  | `:waveshine` | `direction:` | Fox/Falco shine, jump-cancel, wavedash out |
  | `:short_hop_laser` | — | Fox/Falco SH laser with fast fall |
  | `:djc_aerial` | `aerial:` | Ness/Mewtwo/Yoshi/Peach double-jump-cancelled aerial |
  | `:di` | `stick: :up \\| :down \\| :left \\| :right \\| {x, y}` | hold launch DI through hitlag plus the resolution frame |
  | `:sdi` | `direction:` | alternate cardinal/diagonal each hitlag frame (fresh input per frame) |
  | `:asdi_down` | — | park the c-stick down through hitlag; compose with `:tech` for the Amsah tech |
  | `:shadow_ball_charge` | `frames:` (default 60) | Mewtwo charge; shield-cancel stores it (a full charge parks in its own hold loop) |
  | `:shadow_ball_fire` | — | B resumes the stored charge; a SECOND B edge releases the ball |
  | `:teledgehog` | `direction:`, `edge_x:` (default 85.57, FD), `dive_y:` | turn to face the stage, hop out past the lip, sink, snap the ledge (teleport up through the grab zone as the fallback) |
  | `:jc_grab` | — | Z during jumpsquat: the jump cancels into a STANDING grab, even from a dash |
  | `:moonwalk` | `direction:` (the dash side), `dash_frames:`, `slide_frames:` | dash, roll the stick through down into down-back: the dash animation plays while the velocity reverses |
  | `:fox_trot` | `direction:`, `reps:`, `dash_frames:` | chained initial dashes with one-frame gaps — never maturing into a run |
  | `:crouch_cancel` | — | full-down (plus c-stick ASDI) before the hit: 2/3 knockback; done when hitlag resolves |
  | `:wavedash_oos` | `direction:` | shield on R, jump-cancel, L-airdodge diagonally |
  | `:powershield` | — | the shield press + GuardReflect verification; the CALLER times it off projectile tracking |
  | `:shield_drop` | `notch_y:` (default 0.16) | on a platform: shield, tilt into the drop band, fall through |
  | `:drillshine` | — | SHFFL'd dair, then pulse the shine out of the L-cancelled landing |
  | `:double_laser` | — | Falco SH double laser: B edges pulsed through the hop |
  | `:shine_turnaround` | — | tap back mid-shine; facing flips without leaving the shine |
  | `:float_cancel` | `aerial:`, `float_frames:` | Peach full hop, float armed at the apex (down-tap, jump held), float-aerial, release and land |
  | `:gentleman` | — | Falcon jab1-jab2-jab3 with SLOW links (mashing buffers the rapid jab) |
  | `:pivot_smash` | `direction:`, `dash_frames:` | Marth pivot with a c-stick fsmash on the turn frame |
  | `:missile_cancel` | `direction:` | Samus SH side-B; the landing cancels the missile animation (actionable in ~2 frames, live-measured) |
  | `:ics_desync` | — | Popo's grab connects (Nana's whiffs), then B has only Nana answer: solo blizzard |
  | `:shine_grab` | — | Fox/Falco shine, jump-cancel, Z in jumpsquat: the JC grab out of a shine |
  | `:instant_rar` | `direction:`, `run_frames:` | run, turnaround jump, bair while drifting the original way |
  | `:uthrow_uair` | — | thunders combo: grab, up-throw, full-hop uair into the hitstun |
  | `:super_wavedash` | `direction:`, `flick_frame:` (sweep it), `slide_frames:` | Samus SWD: standing bomb, away-then-toward on the morph ball touchdown frames |
  | `:no_impact_land` | `trigger_y:` (sweep it), `hop: :short \\| :full` | NIL: double-jump timed so the apex barely crosses a platform lip — ZERO landing frames |
  | `:v_cancel` | `press_frame:` (sweep it) | full hop, then an airdodge INPUT 1-2f before an incoming hit: ~5% less knockback, the dodge never comes out |
  | `:pkt2` | `steer:` (segments of `{tilt_x, tilt_y, frames}`) | Ness grounded PK Thunder walked around a climb-then-loop back into his own head (bolt turns ~6 deg/frame, radius ~19 — measured) |
  | `:walljump` | `direction:`, `edge_x:`, `out_frames:`, `pin_frames:` | get beside the wall (hop-out or ledge drop), hug in to contact, tap AWAY (UNVERIFIED live: no probed entry ever registered wall contact — see melee-tech.md) |
  | `:walltech` | `wall_x:`, `margin:` | ONE L press + both sticks INTO the wall from a damage state near the wall plane (UNVERIFIED live, same caveat) |
  | `:wobble` | `interval:` (sweep ~28-36), `reps:` | ICs: desync grab, then down+A on a metronome — Popo pummels while Nana (6f late) dtilts; the down is PARKED in CatchPull (a fresh edge in CatchWait is a throw) |
  | `:illusion` | `direction:`, `shorten_frame:` | Fox/Falco side-B; the second B press shortens it (its own action id, 0x160) |
  | `:haxdash` | `dj_delay:` | ledge release -> instant double jump back to the regrab, facing never turns, intangibility refreshed |
  | `:ledgestall` | `delay:` | ledge release -> up-B back into the regrab (Marth dolphin-slash stall) |
  | `:ledgehop_laser` | `direction:`, `fire_delay:` | Falco: ledge release -> DJ over the lip -> B pulses: two lasers before landing |
  | `:pivot_grab` | `direction:`, `dash_frames:` | the empty pivot with Z on the flick: a standing grab facing the new way |
  | `:boost_grab` | `direction:`, `dash_frames:`, `z_delay:` | dash attack cancelled by Z: the grab keeps the dash attack's slide |

  `:shffl` also takes `drift: :left \\| :right` — the main stick held
  through the hop and fall, for landings that slide (edge cancels).

  ## Timing sources

  Jumpsquat frames are character data (Fox 3, Falco 5, Bowser 8...)
  compiled in from the community-standard NTSC table — the one
  per-character input this tier needs. The L-cancel window is 7 frames
  before landing; `:shffl` covers it by pulsing L on a 6-frame period
  during the falling aerial, which guarantees a press edge inside any
  7-frame window without predicting the landing frame.
  """

  alias Melee.{Controller, Enums, PlayerState}

  @type routine ::
          :short_hop
          | :full_hop
          | :wavedash
          | :dash_dance
          | :shffl
          | :multishine
          | :fast_fall
          | :waveland
          | :pivot
          | :tech
          | :ledgedash
          | :waveshine
          | :short_hop_laser
          | :djc_aerial
          | :di
          | :sdi
          | :asdi_down
          | :shadow_ball_charge
          | :shadow_ball_fire
          | :teledgehog
          | :jc_grab
          | :moonwalk
          | :fox_trot
          | :crouch_cancel
          | :wavedash_oos
          | :powershield
          | :shield_drop
          | :drillshine
          | :double_laser
          | :shine_turnaround
          | :float_cancel
          | :gentleman
          | :pivot_smash
          | :missile_cancel
          | :ics_desync
          | :shine_grab
          | :instant_rar
          | :uthrow_uair
          | :super_wavedash
          | :no_impact_land
          | :v_cancel
          | :pkt2
          | :walljump
          | :walltech
          | :wobble
          | :illusion
          | :haxdash
          | :ledgestall
          | :ledgehop_laser
          | :pivot_grab
          | :boost_grab
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
  @aerial_jumps [0x1B, 0x1C]
  @tumbling 0x26

  @landing_special 0x2B
  @shine_ground_start Enums.Action.to_id(:down_b_ground_start)
  @shine_ground Enums.Action.to_id(:down_b_ground)
  @shine_stun Enums.Action.to_id(:down_b_stun)
  @aerial_attacks 0x41..0x45
  @aerial_landings 0x46..0x4A
  # Damage family + tumble: the states a tech is armed from (an
  # up-smash launch rides 0x50 DamageHi through the arc, so the whole
  # 0x4B..0x5B block counts; grounded-only members are filtered by the
  # airborne check at the arming site).
  @hitstun_air MapSet.new(Enum.to_list(0x4B..0x5B) ++ [@tumbling])
  @tech_states [0xC7, 0xC8, 0xC9]
  @missed_tech_states [0xB7, 0xBF]
  @wall_tech 0xCA
  @wall_tech_jump 0xCB
  # Catch (212) through CatchWait (216): the grab came out / connected.
  @grab_actions 0xD4..0xD8
  @jab1 0x2C
  @jab2 0x2D
  @jab3 0x2E
  @rapid_jab_start 0x2F
  # AttackS4Hi..AttackS4Lw: the five fsmash angle variants.
  @fsmash_actions 0x3A..0x3E
  @shield_reflect 0xB6
  @platform_drop 0xF4
  @edge_catch 0xFC
  @edge_hanging 0xFD
  @shield_actions MapSet.new([178, 179, 180])
  @neutral_b_charging 0x156
  @neutral_b_full 0x157
  @neutral_b_cancel 0x158
  @neutral_b_fire 0x159

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
  @routines [
    :short_hop,
    :full_hop,
    :wavedash,
    :dash_dance,
    :shffl,
    :multishine,
    :fast_fall,
    :waveland,
    :pivot,
    :tech,
    :ledgedash,
    :waveshine,
    :short_hop_laser,
    :djc_aerial,
    :di,
    :sdi,
    :asdi_down,
    :shadow_ball_charge,
    :shadow_ball_fire,
    :teledgehog,
    :jc_grab,
    :moonwalk,
    :fox_trot,
    :crouch_cancel,
    :wavedash_oos,
    :powershield,
    :shield_drop,
    :drillshine,
    :double_laser,
    :shine_turnaround,
    :float_cancel,
    :gentleman,
    :pivot_smash,
    :missile_cancel,
    :ics_desync,
    :shine_grab,
    :instant_rar,
    :uthrow_uair,
    :super_wavedash,
    :no_impact_land,
    :v_cancel,
    :pkt2,
    :walljump,
    :walltech,
    :wobble,
    :illusion,
    :haxdash,
    :ledgestall,
    :ledgehop_laser,
    :pivot_grab,
    :boost_grab
  ]

  @spec new(routine(), atom() | integer(), keyword()) :: t()
  def new(routine, character, opts \\ []) when routine in @routines do
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
  def step(%__MODULE__{} = tech, %PlayerState{} = player),
    do: dispatch(tech.routine, tech, player)

  defp dispatch(:short_hop, tech, player), do: hop(tech, player, :short)
  defp dispatch(:full_hop, tech, player), do: hop(tech, player, :full)
  defp dispatch(:wavedash, tech, player), do: wavedash(tech, player)
  defp dispatch(:dash_dance, tech, player), do: dash_dance(tech, player)
  defp dispatch(:shffl, tech, player), do: shffl(tech, player)
  defp dispatch(:multishine, tech, player), do: multishine(tech, player)
  defp dispatch(:fast_fall, tech, player), do: fast_fall(tech, player)
  defp dispatch(:waveland, tech, player), do: waveland(tech, player)
  defp dispatch(:pivot, tech, player), do: pivot(tech, player)
  defp dispatch(:tech, tech, player), do: ground_tech(tech, player)
  defp dispatch(:ledgedash, tech, player), do: ledgedash(tech, player)
  defp dispatch(:waveshine, tech, player), do: waveshine(tech, player)
  defp dispatch(:short_hop_laser, tech, player), do: short_hop_laser(tech, player)
  defp dispatch(:djc_aerial, tech, player), do: djc_aerial(tech, player)
  defp dispatch(:di, tech, player), do: di(tech, player)
  defp dispatch(:sdi, tech, player), do: sdi(tech, player)
  defp dispatch(:asdi_down, tech, player), do: asdi_down(tech, player)
  defp dispatch(:shadow_ball_charge, tech, player), do: shadow_ball_charge(tech, player)
  defp dispatch(:shadow_ball_fire, tech, player), do: shadow_ball_fire(tech, player)
  defp dispatch(:teledgehog, tech, player), do: teledgehog(tech, player)
  defp dispatch(:jc_grab, tech, player), do: jc_grab(tech, player)
  defp dispatch(:moonwalk, tech, player), do: moonwalk(tech, player)
  defp dispatch(:fox_trot, tech, player), do: fox_trot(tech, player)
  defp dispatch(:crouch_cancel, tech, player), do: crouch_cancel(tech, player)
  defp dispatch(:wavedash_oos, tech, player), do: wavedash_oos(tech, player)
  defp dispatch(:powershield, tech, player), do: powershield(tech, player)
  defp dispatch(:shield_drop, tech, player), do: shield_drop(tech, player)
  defp dispatch(:drillshine, tech, player), do: drillshine(tech, player)
  defp dispatch(:double_laser, tech, player), do: double_laser(tech, player)
  defp dispatch(:shine_turnaround, tech, player), do: shine_turnaround(tech, player)
  defp dispatch(:float_cancel, tech, player), do: float_cancel(tech, player)
  defp dispatch(:gentleman, tech, player), do: gentleman(tech, player)
  defp dispatch(:pivot_smash, tech, player), do: pivot_smash(tech, player)
  defp dispatch(:missile_cancel, tech, player), do: missile_cancel(tech, player)
  defp dispatch(:ics_desync, tech, player), do: ics_desync(tech, player)
  defp dispatch(:shine_grab, tech, player), do: shine_grab(tech, player)
  defp dispatch(:instant_rar, tech, player), do: instant_rar(tech, player)
  defp dispatch(:uthrow_uair, tech, player), do: uthrow_uair(tech, player)
  defp dispatch(:super_wavedash, tech, player), do: super_wavedash(tech, player)
  defp dispatch(:no_impact_land, tech, player), do: no_impact_land(tech, player)
  defp dispatch(:v_cancel, tech, player), do: v_cancel(tech, player)
  defp dispatch(:pkt2, tech, player), do: pkt2(tech, player)
  defp dispatch(:walljump, tech, player), do: walljump(tech, player)
  defp dispatch(:walltech, tech, player), do: walltech(tech, player)
  defp dispatch(:wobble, tech, player), do: wobble(tech, player)
  defp dispatch(:illusion, tech, player), do: illusion(tech, player)
  defp dispatch(:haxdash, tech, player), do: haxdash(tech, player)
  defp dispatch(:ledgestall, tech, player), do: ledgestall(tech, player)
  defp dispatch(:ledgehop_laser, tech, player), do: ledgehop_laser(tech, player)
  defp dispatch(:pivot_grab, tech, player), do: pivot_grab(tech, player)
  defp dispatch(:boost_grab, tech, player), do: boost_grab(tech, player)

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

      # `drift:` holds the main stick sideways through the hop and
      # fall so the landing carries slide momentum (edge cancels).
      # Only c-stick aerials compose with it: a drifted main turns a
      # plain A press into fair/bair.
      commands =
        case @aerial_stick[aerial] do
          nil -> [{:release, :y}, {:press, :a}]
          {cx, cy} -> [{:release, :y}, {:tilt, :main, drift_x(tech), 0.5}, {:tilt, :c, cx, cy}]
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
         [{:release, :a}, {:tilt, :c, 0.5, 0.5}, {:tilt, :main, drift_x(tech), 0.0}]}

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
  ## Tier 2: fast fall, waveland, pivot, tech, ledgedash
  ## ------------------------------------------------------------------

  # One down-tap at the moment the character is airborne and falling.
  defp fast_fall(%{phase: :init} = tech, player) do
    if not player.on_ground and player.speed_y_self < 0 do
      {:cont, %{tech | phase: :tapping}, [{:tilt, :main, 0.5, 0.0}]}
    else
      {:cont, tech, []}
    end
  end

  defp fast_fall(%{phase: :tapping} = tech, _player),
    do: {:done, tech, [{:tilt, :main, 0.5, 0.5}]}

  # The wavedash's airdodge half from an already-airborne position:
  # dodge diagonally into the ground (or a platform underfoot).
  defp waveland(%{phase: :init} = tech, player) do
    if player.on_ground do
      {:cont, tech, []}
    else
      x =
        case Keyword.get(tech.opts, :direction, :neutral) do
          :left -> 0.05
          :right -> 0.95
          :neutral -> 0.5
        end

      {:cont, %{tech | phase: :airdodge, counter: 0}, [{:tilt, :main, x, 0.2}, {:press, :l}]}
    end
  end

  defp waveland(%{phase: :airdodge, counter: c} = tech, player) do
    cond do
      player.action == @landing_special -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:release, :l}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Empty pivot: dash one way, flick the OTHER way for exactly one
  # frame, neutral — ends standing, facing flipped, with no slide.
  defp pivot(%{phase: :init} = tech, %{on_ground: true}) do
    x = if Keyword.get(tech.opts, :direction, :right) == :right, do: 1.0, else: 0.0
    dash = Keyword.get(tech.opts, :dash_frames, 6)
    {:cont, %{tech | phase: :dashing, counter: dash}, [{:tilt, :main, x, 0.5}]}
  end

  defp pivot(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp pivot(%{phase: :dashing, counter: c} = tech, _player) when c > 1 do
    {:cont, %{tech | counter: c - 1}, []}
  end

  defp pivot(%{phase: :dashing} = tech, _player) do
    x = if Keyword.get(tech.opts, :direction, :right) == :right, do: 0.0, else: 1.0
    {:cont, %{tech | phase: :flick}, [{:tilt, :main, x, 0.5}]}
  end

  defp pivot(%{phase: :flick} = tech, _player),
    do: {:cont, %{tech | phase: :settle, counter: 0}, [{:tilt, :main, 0.5, 0.5}]}

  defp pivot(%{phase: :settle, counter: c} = tech, player) do
    cond do
      player.action == @standing -> {:done, tech, []}
      c > 20 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Ground tech: ONE L press when a tumbling/damage-falling character
  # gets close to the ground — never pulsed, because an early press
  # locks the tech out for 40 frames. `direction:` picks the getup
  # (:in_place default, :left / :right roll via the stick held from
  # the press).
  defp ground_tech(%{phase: :init} = tech, player) do
    armed? =
      not player.on_ground and MapSet.member?(@hitstun_air, int(player.action)) and
        player.speed_y_self + player.speed_y_attack < 0 and
        player.position.y < Keyword.get(tech.opts, :height, 8.0)

    if armed? do
      stick =
        case Keyword.get(tech.opts, :direction, :in_place) do
          :in_place -> {0.5, 0.5}
          :left -> {0.0, 0.5}
          :right -> {1.0, 0.5}
        end

      {x, y} = stick
      {:cont, %{tech | phase: :pressed, counter: 0}, [{:press, :l}, {:tilt, :main, x, y}]}
    else
      {:cont, tech, []}
    end
  end

  defp ground_tech(%{phase: :pressed, counter: c} = tech, player) do
    action = int(player.action)

    cond do
      action in @tech_states -> {:done, tech, [:release_all]}
      action in @missed_tech_states -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:release, :l}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Ledgedash: release the ledge, double-jump in toward the stage, and
  # waveland onto it — keeping the ledge invincibility (galint).
  # `direction:` is where the STAGE is relative to the ledge.
  defp ledgedash(%{phase: :init} = tech, player) do
    if int(player.action) == @edge_hanging do
      # Release with a tap AWAY from the stage (down also works; away
      # avoids fast-fall accidents).
      x = if stage_side(tech) == :right, do: 0.05, else: 0.95
      {:cont, %{tech | phase: :released, counter: 0}, [{:tilt, :main, x, 0.5}]}
    else
      {:cont, tech, []}
    end
  end

  defp ledgedash(%{phase: :released, counter: c} = tech, _player) do
    # Neutral for a beat so the release registers before the jump.
    if c >= 1 do
      x = if stage_side(tech) == :right, do: 0.95, else: 0.05
      {:cont, %{tech | phase: :jumping, counter: 0}, [{:tilt, :main, x, 0.5}, {:press, :y}]}
    else
      {:cont, %{tech | counter: c + 1}, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  defp ledgedash(%{phase: :jumping, counter: c} = tech, player) do
    x = if stage_side(tech) == :right, do: 0.95, else: 0.05

    cond do
      # Ride the double jump until it has carried the character ABOVE
      # the stage lip — dodging from below dives to a death, and
      # dodging from BESIDE the stage runs into its wall and slides
      # down it (both measured). Above the lip, the diagonal dodge
      # crosses onto the surface.
      int(player.action) in @aerial_jumps and
          player.position.y > Keyword.get(tech.opts, :dodge_height, 1.0) ->
        {:cont, %{tech | phase: :airdodge, counter: 0},
         [{:release, :y}, {:tilt, :main, x, 0.2}, {:press, :l}]}

      c >= 40 ->
        # Give up waiting (weak jump / unexpected state): dodge in
        # rather than drift forever.
        {:cont, %{tech | phase: :airdodge, counter: 0},
         [{:release, :y}, {:tilt, :main, x, 0.2}, {:press, :l}]}

      true ->
        # Keep drifting in toward the stage while the jump rises.
        {:cont, %{tech | counter: c + 1}, [{:release, :y}, {:tilt, :main, x, 0.5}]}
    end
  end

  defp ledgedash(%{phase: :airdodge, counter: c} = tech, player) do
    cond do
      player.action == @landing_special -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:release, :l}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp stage_side(tech), do: Keyword.get(tech.opts, :direction, :right)

  ## ------------------------------------------------------------------
  ## Tier 3: waveshine, short-hop laser, DJC aerials
  ## ------------------------------------------------------------------

  # Fox/Falco waveshine: shine, jump-cancel it, waveland out.
  defp waveshine(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :shining}, [{:press, :b}, {:tilt, :main, 0.5, 0.0}]}

  defp waveshine(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp waveshine(%{phase: :shining} = tech, player) do
    cancellable? =
      int(player.action) in [@shine_ground_start, @shine_stun] and player.action_frame >= 3 and
        player.on_ground

    if cancellable? do
      {:cont, %{tech | phase: :jump_cancel},
       [{:release, :b}, {:tilt, :main, 0.5, 0.5}, {:press, :y}]}
    else
      {:cont, tech, [{:release, :b}]}
    end
  end

  defp waveshine(%{phase: :jump_cancel} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      x =
        case Keyword.get(tech.opts, :direction, :neutral) do
          :left -> 0.05
          :right -> 0.95
          :neutral -> 0.5
        end

      {:cont, %{tech | phase: :airdodge, counter: 0},
       [{:release, :y}, {:tilt, :main, x, 0.2}, {:press, :l}]}
    end
  end

  defp waveshine(%{phase: :airdodge, counter: c} = tech, player) do
    cond do
      player.action == @landing_special -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:release, :l}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Fox/Falco short-hop laser: SH, fire mid-air, fast fall, land.
  defp short_hop_laser(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :hop}, [{:press, :y}]}

  defp short_hop_laser(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp short_hop_laser(%{phase: :hop} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      {:cont, %{tech | phase: :firing, counter: 0}, [{:release, :y}, {:press, :b}]}
    end
  end

  defp short_hop_laser(%{phase: :firing, counter: c} = tech, player) do
    cond do
      player.on_ground ->
        {:done, tech, [:release_all]}

      player.speed_y_self < 0 and c == 0 ->
        {:cont, %{tech | counter: 1}, [{:release, :b}, {:tilt, :main, 0.5, 0.0}]}

      true ->
        {:cont, tech, [{:release, :b}]}
    end
  end

  # Double-jump-cancel aerial (Ness / Mewtwo / Yoshi / Peach): jump,
  # double jump, and immediately aerial — the attack cancels the second
  # jump's rise for a low, fast hit.
  defp djc_aerial(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :hop}, [{:press, :y}]}

  defp djc_aerial(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp djc_aerial(%{phase: :hop} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      {:cont, %{tech | phase: :double_jump}, [{:release, :y}]}
    end
  end

  defp djc_aerial(%{phase: :double_jump} = tech, _player),
    do: {:cont, %{tech | phase: :attack, counter: 0}, [{:press, :x}]}

  defp djc_aerial(%{phase: :attack, counter: 0} = tech, _player) do
    aerial = Keyword.get(tech.opts, :aerial, :nair)

    commands =
      case @aerial_stick[aerial] do
        nil -> [{:release, :x}, {:press, :a}]
        {cx, cy} -> [{:release, :x}, {:tilt, :c, cx, cy}]
      end

    {:cont, %{tech | counter: 1}, commands}
  end

  defp djc_aerial(%{phase: :attack} = tech, player) do
    if player.on_ground do
      {:done, tech, [:release_all]}
    else
      {:cont, tech, [{:release, :a}, {:tilt, :c, 0.5, 0.5}]}
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

  ## ------------------------------------------------------------------
  ## Tier 4: hit-response — DI, SDI, ASDI
  ## ------------------------------------------------------------------

  # Trajectory DI: the launch angle is influenced by the stick position
  # when hitlag RESOLVES, so hold the chosen position through hitlag
  # and one frame past it.
  defp di(%{phase: :init} = tech, player) do
    if player.hitlag_left > 0 do
      {x, y} = di_stick(tech)
      {:cont, %{tech | phase: :holding}, [{:tilt, :main, x, y}]}
    else
      {:cont, tech, []}
    end
  end

  defp di(%{phase: :holding} = tech, player) do
    {x, y} = di_stick(tech)

    if player.hitlag_left > 0 do
      {:cont, tech, [{:tilt, :main, x, y}]}
    else
      # One extra held frame covers the resolution frame, then neutral.
      {:done, tech, [{:tilt, :main, x, y}]}
    end
  end

  defp di_stick(tech) do
    case Keyword.get(tech.opts, :stick, :up) do
      {x, y} -> {x, y}
      :up -> {0.5, 1.0}
      :down -> {0.5, 0.0}
      :left -> {0.0, 0.5}
      :right -> {1.0, 0.5}
    end
  end

  # Smash DI: each re-entry of the stick into a new zone during hitlag
  # is one SDI input (~6 units each). Alternate between the chosen
  # cardinal and its neighboring diagonal every frame for the maximum
  # input rate.
  defp sdi(%{phase: :init} = tech, player) do
    if player.hitlag_left > 0 do
      sdi(%{tech | phase: :mashing, counter: 0}, player)
    else
      {:cont, tech, []}
    end
  end

  defp sdi(%{phase: :mashing, counter: c} = tech, player) do
    if player.hitlag_left > 0 do
      {cardinal, diagonal} =
        case Keyword.get(tech.opts, :direction, :up) do
          :up -> {{0.5, 1.0}, {0.85, 0.9}}
          :down -> {{0.5, 0.0}, {0.85, 0.1}}
          :left -> {{0.0, 0.5}, {0.1, 0.85}}
          :right -> {{1.0, 0.5}, {0.9, 0.85}}
        end

      {x, y} = if rem(c, 2) == 0, do: cardinal, else: diagonal
      {:cont, %{tech | counter: c + 1}, [{:tilt, :main, x, y}]}
    else
      {:done, tech, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  # ASDI down: the c-stick position at the END of hitlag gives an
  # automatic half-unit shift — down is the survival one (into the
  # ground, where :tech converts it into an Amsah tech). The c-stick
  # overrides the main stick for ASDI, so this composes with :di.
  defp asdi_down(%{phase: :init} = tech, player) do
    if player.hitlag_left > 0 do
      {:cont, %{tech | phase: :holding}, [{:tilt, :c, 0.5, 0.0}]}
    else
      {:cont, tech, []}
    end
  end

  defp asdi_down(%{phase: :holding} = tech, player) do
    if player.hitlag_left > 0 do
      {:cont, tech, [{:tilt, :c, 0.5, 0.0}]}
    else
      {:done, tech, [{:tilt, :c, 0.5, 0.5}]}
    end
  end

  ## ------------------------------------------------------------------
  ## Mewtwo: shadow ball, teledgehog
  ## ------------------------------------------------------------------

  # Charge shadow ball for `frames:`, then shield-cancel — the charge
  # is STORED and a later :shadow_ball_fire releases it.
  defp shadow_ball_charge(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :starting}, [{:press, :b}]}

  defp shadow_ball_charge(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp shadow_ball_charge(%{phase: :starting} = tech, player) do
    if int(player.action) == @neutral_b_charging do
      {:cont, %{tech | phase: :charging, counter: 0}, [{:release, :b}]}
    else
      {:cont, tech, [{:release, :b}]}
    end
  end

  defp shadow_ball_charge(%{phase: :charging, counter: c} = tech, player) do
    cond do
      # A full charge parks in its own hold loop; cancel out of it too.
      int(player.action) == @neutral_b_full or
          c >= Keyword.get(tech.opts, :frames, 60) ->
        {:cont, %{tech | phase: :cancelling, counter: 0}, [{:press, :l}]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp shadow_ball_charge(%{phase: :cancelling, counter: c} = tech, player) do
    cond do
      int(player.action) == @neutral_b_cancel or
        MapSet.member?(@shield_actions, int(player.action)) or
          int(player.action) == @standing ->
        {:done, tech, [:release_all]}

      c >= 2 ->
        {:cont, %{tech | counter: c + 1}, [{:release, :l}]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Release the (stored) shadow ball. A B press with a stored charge
  # RESUMES charging — the release itself needs a SECOND B edge from
  # inside the charge loop.
  defp shadow_ball_fire(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :resuming, counter: 0}, [{:press, :b}]}

  defp shadow_ball_fire(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp shadow_ball_fire(%{phase: :resuming, counter: c} = tech, player) do
    cond do
      int(player.action) in [@neutral_b_charging, @neutral_b_full] ->
        {:cont, %{tech | phase: :refire, counter: 0}, [{:release, :b}]}

      c >= 30 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}]}
    end
  end

  defp shadow_ball_fire(%{phase: :refire, counter: c} = tech, _player) do
    if c >= 2 do
      {:cont, %{tech | phase: :firing, counter: 0}, [{:press, :b}]}
    else
      {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp shadow_ball_fire(%{phase: :firing, counter: c} = tech, player) do
    cond do
      int(player.action) == @neutral_b_fire -> {:done, tech, [:release_all]}
      c >= 30 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Teledgehog: hop past the ledge (backward drift keeps the facing
  # toward the stage), fall below ledge level, then teleport UP so the
  # travel passes through the ledge's grab zone and snaps to the hang.
  # `direction:` is which side's ledge (default :right); `edge_x:` is
  # the stage lip's |x| (default 85.57, FD).
  defp teledgehog(%{phase: :init} = tech, %{on_ground: true} = player) do
    facing_ledge? = if ledge_right?(tech), do: player.facing, else: not player.facing

    if facing_ledge? do
      # A fall only grabs a ledge it FACES: turn away before hopping.
      x = if ledge_right?(tech), do: 0.2, else: 0.8
      {:cont, tech, [{:tilt, :main, x, 0.5}]}
    else
      {:cont, %{tech | phase: :hop}, [{:tilt, :main, 0.5, 0.5}, {:press, :y}]}
    end
  end

  defp teledgehog(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp teledgehog(%{phase: :hop} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      {:cont, %{tech | phase: :out, counter: 0}, [{:release, :y}]}
    end
  end

  # Backward-drift off the stage, sink below ledge level, then up-B.
  defp teledgehog(%{phase: :out, counter: c} = tech, player) do
    out = Keyword.get(tech.opts, :edge_x, 85.57) + 2.0
    past? = abs(player.position.x) > out
    dive_y = Keyword.get(tech.opts, :dive_y, -15.0)
    x = if ledge_right?(tech), do: 0.9, else: 0.1

    cond do
      # The lip-hugging fall can grab the ledge on its own — done.
      int(player.action) in [@edge_catch, @edge_hanging] ->
        {:done, tech, [:release_all]}

      c >= 120 ->
        {:done, tech, [:release_all]}

      past? and player.position.y < dive_y ->
        # Aim mostly up, a touch toward the stage: the travel crosses
        # the grab zone just below the lip.
        aim_x = if ledge_right?(tech), do: 0.35, else: 0.65

        {:cont, %{tech | phase: :teleporting, counter: 0},
         [{:tilt, :main, aim_x, 1.0}, {:press, :b}]}

      past? ->
        # Hold back toward the stage: kill the outward momentum so the
        # sink hugs the lip.
        back = if ledge_right?(tech), do: 0.1, else: 0.9
        {:cont, %{tech | counter: c + 1}, [{:tilt, :main, back, 0.5}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:tilt, :main, x, 0.5}]}
    end
  end

  defp teledgehog(%{phase: :teleporting, counter: c} = tech, player) do
    action = int(player.action)
    aim_x = if ledge_right?(tech), do: 0.35, else: 0.65
    back = if ledge_right?(tech), do: 0.1, else: 0.9

    cond do
      action in [@edge_catch, @edge_hanging] ->
        {:done, tech, [:release_all]}

      c >= 120 ->
        {:done, tech, [:release_all]}

      # Reappeared onto the stage: stop (no snap this attempt).
      c > 5 and player.on_ground and action < 0x40 ->
        {:done, tech, [:release_all]}

      # Reappeared into a fall: drift toward the stage so the fall
      # hugs the ledge.
      c > 5 and not player.on_ground and action < 0x40 ->
        {:cont, %{tech | counter: c + 1}, [{:tilt, :main, back, 0.5}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}, {:tilt, :main, aim_x, 1.0}]}
    end
  end

  defp ledge_right?(tech), do: Keyword.get(tech.opts, :direction, :right) == :right

  ## ------------------------------------------------------------------
  ## Tier 5: the universal batch
  ## ------------------------------------------------------------------

  # JC grab: press Z during jumpsquat — the jump cancels into a
  # STANDING grab even out of a dash (faster + longer-lasting than the
  # dash grab it replaces).
  defp jc_grab(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :squat}, [{:press, :y}]}

  defp jc_grab(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp jc_grab(%{phase: :squat} = tech, player) do
    if int(player.action) == @knee_bend do
      {:cont, %{tech | phase: :grabbing, counter: 0}, [{:release, :y}, {:press, :z}]}
    else
      {:cont, tech, [{:release, :y}]}
    end
  end

  defp jc_grab(%{phase: :grabbing, counter: c} = tech, player) do
    cond do
      int(player.action) in @grab_actions -> {:done, tech, [:release_all]}
      c >= 15 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, [{:release, :z}]}
    end
  end

  # Moonwalk: dash one way, roll the stick through straight-down into
  # the down-back diagonal — the dash animation keeps playing while
  # the velocity reverses. `direction:` is the DASH direction; the
  # slide goes the other way.
  defp moonwalk(%{phase: :init} = tech, %{on_ground: true} = player) do
    # The dash needs a fresh smash input FROM NEUTRAL — starting out
    # of a walk just walks faster. Hold neutral until standing.
    if int(player.action) == @standing do
      x = if dir_right?(tech), do: 1.0, else: 0.0
      n = Keyword.get(tech.opts, :dash_frames, 4)
      {:cont, %{tech | phase: :dashing, counter: n}, [{:tilt, :main, x, 0.5}]}
    else
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  defp moonwalk(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp moonwalk(%{phase: :dashing, counter: c} = tech, _player) when c > 1,
    do: {:cont, %{tech | counter: c - 1}, []}

  defp moonwalk(%{phase: :dashing} = tech, _player) do
    # Roll along the bottom rim — one frame down-forward, no lingering
    # in full-down (that crouch-cancels the dash).
    x = if dir_right?(tech), do: 0.65, else: 0.35
    {:cont, %{tech | phase: :roll}, [{:tilt, :main, x, 0.08}]}
  end

  defp moonwalk(%{phase: :roll} = tech, _player) do
    # The park must dodge two cancels: |x| >= 0.8 back smash-turns,
    # and deep down crouch-cancels the dash. Down-back at (~-0.7,
    # ~-0.5) reverses the velocity while the dash keeps playing.
    x = if dir_right?(tech), do: 0.12, else: 0.88
    n = Keyword.get(tech.opts, :slide_frames, 20)
    {:cont, %{tech | phase: :sliding, counter: n}, [{:tilt, :main, x, 0.25}]}
  end

  defp moonwalk(%{phase: :sliding, counter: c} = tech, _player) when c > 1,
    do: {:cont, %{tech | counter: c - 1}, []}

  defp moonwalk(%{phase: :sliding} = tech, _player), do: {:done, tech, [:release_all]}

  # Fox trot: chain initial dashes with a one-frame gap — never let
  # the dash mature into a run.
  defp fox_trot(%{phase: :init} = tech, %{on_ground: true}) do
    reps = Keyword.get(tech.opts, :reps, 3)
    x = if dir_right?(tech), do: 1.0, else: 0.0
    {:cont, %{tech | phase: :dashing, counter: 0, aux: reps}, [{:tilt, :main, x, 0.5}]}
  end

  defp fox_trot(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp fox_trot(%{phase: :dashing, counter: c, aux: reps} = tech, player) do
    hold = Keyword.get(tech.opts, :dash_frames, 7)
    x = if dir_right?(tech), do: 1.0, else: 0.0

    # Regap off the DASH's own frame counter — a wall-clock hold can
    # outlast the initial-dash window (entering the dash costs frames
    # too) and mature into the run a trot must never reach.
    mature? = int(player.action) == @dashing and player.action_frame >= hold

    cond do
      not mature? and c < hold + 8 ->
        {:cont, %{tech | counter: c + 1}, [{:tilt, :main, x, 0.5}]}

      reps <= 1 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | phase: :gap, counter: 0, aux: reps - 1}, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  # The initial dash ANIMATION completes regardless of the stick —
  # re-smashing mid-dash just feeds a forward-hold into the run. Stay
  # neutral until the dash action actually ends, then re-smash.
  defp fox_trot(%{phase: :gap, counter: c} = tech, player) do
    x = if dir_right?(tech), do: 1.0, else: 0.0

    cond do
      int(player.action) == @dashing and c < 20 ->
        {:cont, %{tech | counter: c + 1}, []}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | phase: :dashing, counter: 0}, [{:tilt, :main, x, 0.5}]}
    end
  end

  # Crouch cancel: full-down BEFORE the hit multiplies incoming
  # knockback by 2/3, and the held c-stick adds ASDI down. Holds
  # through hitlag plus the resolution frame.
  defp crouch_cancel(%{phase: :init} = tech, player) do
    if player.hitlag_left > 0 do
      {:cont, %{tech | phase: :hitlag}, [{:tilt, :main, 0.5, 0.0}, {:tilt, :c, 0.5, 0.0}]}
    else
      {:cont, tech, [{:tilt, :main, 0.5, 0.0}, {:tilt, :c, 0.5, 0.0}]}
    end
  end

  defp crouch_cancel(%{phase: :hitlag} = tech, player) do
    if player.hitlag_left > 0 do
      {:cont, tech, [{:tilt, :main, 0.5, 0.0}, {:tilt, :c, 0.5, 0.0}]}
    else
      {:done, tech, [{:tilt, :main, 0.5, 0.0}, {:tilt, :c, 0.5, 0.5}]}
    end
  end

  # Wavedash out of shield: shield on R, jump-cancel it, airdodge
  # diagonally with L on the first airborne frame.
  defp wavedash_oos(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :shielding, counter: 0}, [{:press, :r}]}

  defp wavedash_oos(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp wavedash_oos(%{phase: :shielding, counter: c} = tech, player) do
    cond do
      MapSet.member?(@shield_actions, int(player.action)) ->
        {:cont, %{tech | phase: :jumping}, [{:press, :y}]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp wavedash_oos(%{phase: :jumping} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      x =
        case Keyword.get(tech.opts, :direction, :neutral) do
          :left -> 0.05
          :right -> 0.95
          :neutral -> 0.5
        end

      {:cont, %{tech | phase: :airdodge, counter: 0},
       [{:release, :y}, {:release, :r}, {:tilt, :main, x, 0.2}, {:press, :l}]}
    end
  end

  defp wavedash_oos(%{phase: :airdodge, counter: c} = tech, player) do
    cond do
      player.action == @landing_special -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:release, :l}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Powershield: a shield press whose first 2 frames overlap the hit
  # (GuardReflect 0xB6). The routine is the press + verification —
  # the CALLER times `new/3` off its own projectile tracking, since
  # routines only see the player.
  defp powershield(%{phase: :init} = tech, _player),
    do: {:cont, %{tech | phase: :holding, counter: 0}, [{:press, :r}]}

  defp powershield(%{phase: :holding, counter: c} = tech, player) do
    cond do
      int(player.action) == @shield_reflect -> {:done, tech, [:release_all]}
      c >= 20 -> {:done, tech, [:release_all]}
      c >= 8 -> {:cont, %{tech | counter: c + 1}, [{:release, :r}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Shield drop: on a platform, shield and tilt into the narrow down
  # band that drops through without spot-dodging or rolling.
  defp shield_drop(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :shielding, counter: 0}, [{:press, :r}]}

  defp shield_drop(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp shield_drop(%{phase: :shielding, counter: c} = tech, player) do
    cond do
      MapSet.member?(@shield_actions, int(player.action)) ->
        y = Keyword.get(tech.opts, :notch_y, 0.16)
        {:cont, %{tech | phase: :dropping, counter: 0}, [{:tilt, :main, 0.5, y}]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp shield_drop(%{phase: :dropping, counter: c} = tech, player) do
    cond do
      int(player.action) == @platform_drop or not player.on_ground ->
        {:done, tech, [:release_all]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  ## ------------------------------------------------------------------
  ## Tier 5: spacie extensions
  ## ------------------------------------------------------------------

  # Drillshine: SHFFL'd dair (as a sub-machine), then pulse B+down
  # from the L-cancelled landing until the shine comes out.
  defp drillshine(%{phase: :init} = tech, player) do
    sub = new(:shffl, tech.character, aerial: :dair)
    drillshine(%{tech | phase: :drill, aux: sub}, player)
  end

  defp drillshine(%{phase: :drill, aux: sub} = tech, player) do
    case step(sub, player) do
      {:done, _sub, _commands} ->
        {:cont, %{tech | phase: :shine, counter: 0}, [{:press, :b}, {:tilt, :main, 0.5, 0.0}]}

      {:cont, sub, commands} ->
        {:cont, %{tech | aux: sub}, commands}
    end
  end

  defp drillshine(%{phase: :shine, counter: c} = tech, player) do
    cond do
      int(player.action) in [@shine_ground_start, @shine_ground] ->
        {:done, tech, [:release_all]}

      c >= 14 ->
        {:done, tech, [:release_all]}

      # Pulse the B edge through the landing lag so the first
      # actionable frame catches a press.
      rem(c, 2) == 0 ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:press, :b}, {:tilt, :main, 0.5, 0.0}]}
    end
  end

  # Falco short-hop double laser: B edges pulsed through the hop.
  defp double_laser(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :hop}, [{:press, :y}]}

  defp double_laser(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp double_laser(%{phase: :hop} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      {:cont, %{tech | phase: :firing, counter: 0}, [{:release, :y}, {:press, :b}]}
    end
  end

  defp double_laser(%{phase: :firing, counter: c} = tech, player) do
    cond do
      player.on_ground ->
        {:done, tech, [:release_all]}

      rem(c, 2) == 0 ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:press, :b}]}
    end
  end

  # Shine turnaround: tap back mid-shine — the facing flips without
  # leaving the shine.
  defp shine_turnaround(%{phase: :init} = tech, %{on_ground: true} = player) do
    {:cont, %{tech | phase: :shining, counter: 0, aux: player.facing},
     [{:press, :b}, {:tilt, :main, 0.5, 0.0}]}
  end

  defp shine_turnaround(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp shine_turnaround(%{phase: :shining, counter: c} = tech, player) do
    in_shine? =
      int(player.action) in [@shine_ground_start, @shine_ground, @shine_stun]

    cond do
      in_shine? and player.action_frame >= 4 ->
        x = if tech.aux, do: 0.0, else: 1.0
        {:cont, %{tech | phase: :turning, counter: 0}, [{:release, :b}, {:tilt, :main, x, 0.5}]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}]}
    end
  end

  defp shine_turnaround(%{phase: :turning, counter: c} = tech, player) do
    cond do
      player.facing != tech.aux -> {:done, tech, [:release_all]}
      c >= 15 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  defp dir_right?(tech), do: Keyword.get(tech.opts, :direction, :right) == :right

  defp drift_x(tech) do
    case Keyword.get(tech.opts, :drift) do
      :left -> 0.15
      :right -> 0.85
      _ -> 0.5
    end
  end

  ## ------------------------------------------------------------------
  ## Tier 5: character kits
  ## ------------------------------------------------------------------

  # Peach float-cancel aerial: full hop, arm the float near the apex
  # (a down-tap with jump still held), aerial IN the float, release,
  # and land mid-aerial. A GROUND-LEVEL float drop lands the same
  # frame the release registers and takes the 29-frame heavy landing
  # (measured) — the FC needs the height.
  defp float_cancel(%{phase: :init} = tech, %{on_ground: true} = player) do
    if int(player.action) == @standing do
      {:cont, %{tech | phase: :hop}, [{:press, :y}]}
    else
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  defp float_cancel(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp float_cancel(%{phase: :hop} = tech, player) do
    if player.on_ground do
      # Hold jump: full hop, and the held jump is half the float input.
      {:cont, tech, [{:press, :y}]}
    else
      {:cont, %{tech | phase: :float_arm, counter: 0}, []}
    end
  end

  # Arm the float LOW - a down-tap with jump held right after
  # liftoff locks the float a few units up, so the post-release fall
  # lands inside the FC window.
  defp float_cancel(%{phase: :float_arm, counter: c} = tech, player) do
    cond do
      player.speed_y_self < 1.0 ->
        {:cont, %{tech | phase: :float_wait, counter: 0}, [{:tilt, :main, 0.5, 0.25}]}

      not player.on_ground and c >= 30 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp float_cancel(%{phase: :float_wait, counter: c} = tech, player) do
    if int(player.action) >= 0x155 or c >= 15 do
      {:cont, %{tech | phase: :floating, counter: 0}, [{:tilt, :main, 0.5, 0.5}]}
    else
      {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp float_cancel(%{phase: :floating, counter: c} = tech, _player) do
    # A beat in the float, then the aerial IN the float — landing
    # during the attack is the float cancel (a 4-frame landing; our
    # earlier "29f heavy" was the uninterrupted Landing ANIMATION,
    # not the lag — generic Landing is actionable after 4).
    if c >= Keyword.get(tech.opts, :float_frames, 6) do
      aerial = Keyword.get(tech.opts, :aerial, :nair)

      commands =
        case @aerial_stick[aerial] do
          nil -> [{:press, :a}]
          {cx, cy} -> [{:tilt, :c, cx, cy}]
        end

      {:cont, %{tech | phase: :attacking, counter: 0}, commands}
    else
      {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp float_cancel(%{phase: :attacking, counter: c} = tech, player) do
    cond do
      # Float aerials are their own action family: release the float
      # and fast fall so the touchdown lands DURING the attack.
      int(player.action) in 0x158..0x15C ->
        {:cont, %{tech | phase: :landing, counter: 0},
         [{:release, :y}, {:release, :a}, {:tilt, :c, 0.5, 0.5}, {:tilt, :main, 0.5, 0.0}]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :a}, {:tilt, :c, 0.5, 0.5}]}
    end
  end

  defp float_cancel(%{phase: :landing, counter: c} = tech, player) do
    cond do
      player.on_ground ->
        {:done, tech, [:release_all]}

      c >= 60 ->
        {:done, tech, [:release_all]}

      # Fast fall: the FC window is landing within ~4 frames of
      # leaving the float.
      c == 0 ->
        {:cont, %{tech | counter: c + 1}, [{:tilt, :main, 0.5, 0.0}]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Fox/Falco shine grab: shine, jump-cancel it, Z during the
  # jumpsquat — the JC grab out of a (connected) shine.
  defp shine_grab(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :shining}, [{:press, :b}, {:tilt, :main, 0.5, 0.0}]}

  defp shine_grab(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp shine_grab(%{phase: :shining} = tech, player) do
    cancellable? =
      int(player.action) in [@shine_ground_start, @shine_stun] and player.action_frame >= 3 and
        player.on_ground

    if cancellable? do
      {:cont, %{tech | phase: :jc}, [{:release, :b}, {:tilt, :main, 0.5, 0.5}, {:press, :y}]}
    else
      {:cont, tech, [{:release, :b}]}
    end
  end

  defp shine_grab(%{phase: :jc} = tech, player) do
    if int(player.action) == @knee_bend do
      {:cont, %{tech | phase: :grabbing, counter: 0}, [{:release, :y}, {:press, :z}]}
    else
      {:cont, tech, [{:release, :y}]}
    end
  end

  defp shine_grab(%{phase: :grabbing, counter: c} = tech, player) do
    cond do
      int(player.action) in @grab_actions -> {:done, tech, [:release_all]}
      c >= 15 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, [{:release, :z}]}
    end
  end

  # Instant RAR (reverse aerial rush): run, flick backward into the
  # turn, jump out of the turn, and bair while drifting the ORIGINAL
  # way — the momentum carries forward, the attack points backward.
  defp instant_rar(%{phase: :init} = tech, %{on_ground: true} = player) do
    if int(player.action) == @standing do
      x = if dir_right?(tech), do: 1.0, else: 0.0
      run = Keyword.get(tech.opts, :run_frames, 8)
      {:cont, %{tech | phase: :running, counter: run}, [{:tilt, :main, x, 0.5}]}
    else
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  defp instant_rar(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp instant_rar(%{phase: :running, counter: c} = tech, _player) when c > 1,
    do: {:cont, %{tech | counter: c - 1}, []}

  defp instant_rar(%{phase: :running} = tech, _player) do
    x = if dir_right?(tech), do: 0.0, else: 1.0
    {:cont, %{tech | phase: :turn, counter: 0}, [{:tilt, :main, x, 0.5}]}
  end

  defp instant_rar(%{phase: :turn, counter: c} = tech, player) do
    cond do
      int(player.action) in [@turning, 0x13] ->
        {:cont, %{tech | phase: :jumping}, [{:tilt, :main, 0.5, 0.5}, {:press, :y}]}

      c >= 10 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp instant_rar(%{phase: :jumping} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      # Airborne: drift the ORIGINAL direction, bair via the c-stick
      # (which now points the same way — behind the flipped facing).
      x = if dir_right?(tech), do: 0.85, else: 0.15

      {:cont, %{tech | phase: :attacking, counter: 0},
       [{:release, :y}, {:tilt, :main, x, 0.5}, {:tilt, :c, x, 0.5}]}
    end
  end

  defp instant_rar(%{phase: :attacking, counter: c} = tech, player) do
    cond do
      player.on_ground -> {:done, tech, [:release_all]}
      c >= 60 -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:tilt, :c, 0.5, 0.5}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Thunders combo: grab, up-throw, chase with a full-hop uair while
  # the victim is still in hitstun.
  defp uthrow_uair(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :grabbing, counter: 0}, [{:press, :z}]}

  defp uthrow_uair(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp uthrow_uair(%{phase: :grabbing, counter: c} = tech, player) do
    cond do
      # Wait for CatchWait (0xD8) - a stick already held up during
      # the CatchPull has no fresh EDGE left to trigger the throw.
      int(player.action) == 0xD8 ->
        {:cont, %{tech | phase: :throwing, counter: 0},
         [{:release, :z}, {:tilt, :main, 0.5, 1.0}]}

      c >= 30 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :z}]}
    end
  end

  defp uthrow_uair(%{phase: :throwing, counter: c} = tech, player) do
    cond do
      # ThrowUp (0xDD): neutral the stick so the held up doesn't
      # tap-jump the endlag.
      int(player.action) == 0xDD ->
        {:cont, %{tech | phase: :thrown, counter: 0}, [{:tilt, :main, 0.5, 0.5}]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp uthrow_uair(%{phase: :thrown, counter: c} = tech, player) do
    cond do
      # Throw endlag over: jump after the victim.
      int(player.action) < 0x40 and player.on_ground ->
        {:cont, %{tech | phase: :hop}, [{:press, :y}]}

      c >= 40 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp uthrow_uair(%{phase: :hop} = tech, player) do
    if player.on_ground do
      # Full hop: hold the jump through jumpsquat.
      {:cont, tech, [{:press, :y}]}
    else
      {:cont, %{tech | phase: :rising, counter: 0}, [{:release, :y}]}
    end
  end

  # Ride the jump up before swinging - an instant uair passes under
  # the popped victim.
  defp uthrow_uair(%{phase: :rising, counter: c} = tech, _player) do
    if c >= Keyword.get(tech.opts, :uair_delay, 6) do
      {:cont, %{tech | phase: :attacking, counter: 0}, [{:tilt, :c, 0.5, 1.0}]}
    else
      {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp uthrow_uair(%{phase: :attacking, counter: c} = tech, player) do
    cond do
      player.on_ground -> {:done, tech, [:release_all]}
      c >= 90 -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:tilt, :c, 0.5, 0.5}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Falcon gentleman: three SLOW jab links (mashing buffers the rapid
  # jab instead of the third hit).
  defp gentleman(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :w1, counter: 0}, [{:press, :a}]}

  defp gentleman(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp gentleman(%{phase: :w1} = tech, player),
    do: gentleman_link(tech, player, @jab1, :w2)

  defp gentleman(%{phase: :w2} = tech, player),
    do: gentleman_link(tech, player, @jab2, :w3)

  defp gentleman(%{phase: :w3, counter: c} = tech, player) do
    cond do
      int(player.action) in [@jab3, @rapid_jab_start] -> {:done, tech, [:release_all]}
      c >= 40 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, [{:release, :a}]}
    end
  end

  defp gentleman_link(%{counter: c} = tech, player, jab, next) do
    cond do
      int(player.action) == jab and player.action_frame >= 3 ->
        {:cont, %{tech | phase: next, counter: 0}, [{:press, :a}]}

      c >= 40 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :a}]}
    end
  end

  # Marth pivot fsmash: the empty pivot's flick frame, with the
  # c-stick smash landing on the turn.
  defp pivot_smash(%{phase: :init} = tech, %{on_ground: true}) do
    x = if dir_right?(tech), do: 1.0, else: 0.0
    dash = Keyword.get(tech.opts, :dash_frames, 5)
    {:cont, %{tech | phase: :dashing, counter: dash}, [{:tilt, :main, x, 0.5}]}
  end

  defp pivot_smash(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp pivot_smash(%{phase: :dashing, counter: c} = tech, _player) when c > 1,
    do: {:cont, %{tech | counter: c - 1}, []}

  defp pivot_smash(%{phase: :dashing} = tech, _player) do
    x = if dir_right?(tech), do: 0.0, else: 1.0
    {:cont, %{tech | phase: :flick}, [{:tilt, :main, x, 0.5}]}
  end

  defp pivot_smash(%{phase: :flick} = tech, _player) do
    # C-stick smash toward the NEW facing, main back to neutral.
    cx = if dir_right?(tech), do: 0.0, else: 1.0

    {:cont, %{tech | phase: :smashing, counter: 0},
     [{:tilt, :main, 0.5, 0.5}, {:tilt, :c, cx, 0.5}]}
  end

  defp pivot_smash(%{phase: :smashing, counter: c} = tech, player) do
    cond do
      int(player.action) in @fsmash_actions -> {:done, tech, [:release_all]}
      c >= 15 -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:tilt, :c, 0.5, 0.5}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Samus missile cancel: SH side-B; landing during the missile
  # animation is ACTIONABLE in ~2 frames (the landing ANIMATION runs
  # ~30 frames when idle, but generic Landing is interruptible after
  # its lag - an earlier "heavy landing" reading was that artifact).
  defp missile_cancel(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :hop}, [{:press, :y}]}

  defp missile_cancel(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp missile_cancel(%{phase: :hop} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      x = if dir_right?(tech), do: 1.0, else: 0.0

      {:cont, %{tech | phase: :firing, counter: 0},
       [{:release, :y}, {:tilt, :main, x, 0.5}, {:press, :b}]}
    end
  end

  defp missile_cancel(%{phase: :firing, counter: c} = tech, player) do
    cond do
      player.on_ground -> {:done, tech, [:release_all]}
      c >= 90 -> {:done, tech, [:release_all]}
      c >= 1 -> {:cont, %{tech | counter: c + 1}, [{:release, :b}, {:tilt, :main, 0.5, 0.5}]}
      true -> {:cont, %{tech | counter: c + 1}, [{:release, :b}]}
    end
  end

  # Samus super wavedash: lay a standing bomb; on the frame the morph
  # ball touches back down press AWAY, the very next frame press
  # TOWARD — a frame-perfect pair that flings her the length of FD.
  # `flick_frame:` counts frames from the bomb press (sweep it — the
  # game is deterministic, one offset lands the 1-frame window).
  defp super_wavedash(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :bombing, counter: 0}, [{:tilt, :main, 0.5, 0.0}, {:press, :b}]}

  defp super_wavedash(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp super_wavedash(%{phase: :bombing, counter: c} = tech, _player) do
    flick = Keyword.get(tech.opts, :flick_frame, 40)

    cond do
      c >= flick ->
        away = if dir_right?(tech), do: 0.0, else: 1.0
        {:cont, %{tech | phase: :flick}, [{:release, :b}, {:tilt, :main, away, 0.5}]}

      c >= 1 ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}, {:tilt, :main, 0.5, 0.5}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}]}
    end
  end

  defp super_wavedash(%{phase: :flick} = tech, _player) do
    toward = if dir_right?(tech), do: 1.0, else: 0.0
    {:cont, %{tech | phase: :launch}, [{:tilt, :main, toward, 0.5}]}
  end

  defp super_wavedash(%{phase: :launch} = tech, _player) do
    # "Do not continue holding after frame 42" — neutral maximizes
    # the slide.
    {:cont, %{tech | phase: :sliding, counter: 0}, [{:tilt, :main, 0.5, 0.5}]}
  end

  defp super_wavedash(%{phase: :sliding, counter: c} = tech, _player) do
    if c >= Keyword.get(tech.opts, :slide_frames, 30) do
      {:done, tech, [:release_all]}
    else
      {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Ice Climbers grab desync: Popo's grab CONNECTING splits the pair
  # (Nana's whiffs), then B has only Nana answer — she blizzards solo
  # while Popo holds the catch.
  defp ics_desync(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :grabbing, counter: 0}, [{:press, :z}]}

  defp ics_desync(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp ics_desync(%{phase: :grabbing, counter: c} = tech, player) do
    # Nana grabs too (6 frames late) and WHIFFS — hold the B until
    # her catch endlag ends, or she ignores it.
    nana_ready? = player.nana == nil or int(player.nana.action) < 0x40

    cond do
      int(player.action) in [0xD5, 0xD8] and nana_ready? ->
        {:cont, %{tech | phase: :nana_special, counter: 0}, [{:release, :z}, {:press, :b}]}

      c >= 90 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :z}]}
    end
  end

  defp ics_desync(%{phase: :nana_special, counter: c} = tech, _player) do
    cond do
      c >= 25 -> {:done, tech, [:release_all]}
      c >= 1 -> {:cont, %{tech | counter: c + 1}, [{:release, :b}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  ## ------------------------------------------------------------------
  ## Round 6: geometry + launcher techs
  ## ------------------------------------------------------------------

  # No-impact land: a double jump timed so its APEX barely crosses a
  # platform lip — the game snaps to the surface with ZERO landing
  # frames (no Landing action at all). A double jump's apex is exactly
  # press-height + the character's fixed DJ rise, so `trigger_y:` (the
  # height to press the second jump at) IS the apex dial: the caller
  # measures the rise live and sweeps trigger_y = lip + eps - rise.
  defp no_impact_land(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :hop}, [{:press, :y}]}

  defp no_impact_land(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp no_impact_land(%{phase: :hop} = tech, player) do
    cond do
      not player.on_ground ->
        {:cont, %{tech | phase: :rising}, [{:release, :y}]}

      Keyword.get(tech.opts, :hop, :full) == :short ->
        {:cont, tech, [{:release, :y}]}

      true ->
        {:cont, tech, [{:press, :y}]}
    end
  end

  defp no_impact_land(%{phase: :rising} = tech, player) do
    trigger = Keyword.get(tech.opts, :trigger_y, 10.0)

    # `on: :fall` fires the DJ on the way DOWN instead — the two
    # branches sample different press heights (different velocity at
    # the crossing), doubling the apex grid a sweep can reach.
    fire? =
      case Keyword.get(tech.opts, :on, :rise) do
        :rise -> player.position.y >= trigger
        :fall -> player.speed_y_self < 0 and player.position.y <= trigger
      end

    cond do
      # Landed without the DJ (trigger above the hop's own apex).
      player.on_ground ->
        {:done, tech, [:release_all]}

      fire? ->
        {:cont, %{tech | phase: :dj, counter: 0}, [{:press, :x}]}

      true ->
        {:cont, tech, []}
    end
  end

  defp no_impact_land(%{phase: :dj, counter: c} = tech, player) do
    cond do
      player.on_ground -> {:done, tech, [:release_all]}
      c >= 150 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, [{:release, :x}]}
    end
  end

  # V-cancel: an airdodge INPUT 1-2 frames before getting hit while
  # airborne shaves ~5% off the launch knockback; the dodge itself
  # never comes out. Full hop, then L at `press_frame:` airborne
  # frames — sweep it against a scripted launcher (too early = a real
  # airdodge whose intangibility whiffs the hit, a self-labelling
  # attempt).
  defp v_cancel(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :hop}, [{:press, :y}]}

  defp v_cancel(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp v_cancel(%{phase: :hop} = tech, player) do
    if player.on_ground do
      # Full hop: hold the jump through jumpsquat.
      {:cont, tech, [{:press, :y}]}
    else
      # `drift:`/`drift_tilt:` carry the hop sideways (e.g. into a
      # launcher's range) — identical in the control and cancel arms.
      dx = Keyword.get(tech.opts, :drift_tilt, drift_x(tech))
      {:cont, %{tech | phase: :airborne, counter: 0}, [{:release, :y}, {:tilt, :main, dx, 0.5}]}
    end
  end

  defp v_cancel(%{phase: :airborne, counter: c} = tech, player) do
    cond do
      player.hitlag_left > 0 ->
        {:done, tech, [:release_all]}

      player.on_ground ->
        {:done, tech, [:release_all]}

      c >= Keyword.get(tech.opts, :press_frame, 10) ->
        {:cont, %{tech | phase: :pressed, counter: 0}, [{:press, :l}]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp v_cancel(%{phase: :pressed, counter: c} = tech, player) do
    cond do
      player.hitlag_left > 0 -> {:done, tech, [:release_all]}
      player.on_ground -> {:done, tech, [:release_all]}
      c >= 60 -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:release, :l}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Ness PKT2 into himself: grounded PK Thunder, then `steer:` (a list
  # of `{tilt_x, tilt_y, frames}` segments) walks the bolt around a
  # loop back into his own head — the recipe's second half for the
  # thunder jacket. The bolt turns ~6 deg/frame toward the held
  # direction (turn radius ~22 units, measured), so a full self-hit
  # loop dips ~10 units BELOW the cast height and must hang over open
  # air: cast at a lip and loop offstage — over ground the bolt dies
  # on the floor. The default plan loops to ness's right.
  defp pkt2(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :casting, counter: 0}, [{:tilt, :main, 0.5, 1.0}, {:press, :b}]}

  defp pkt2(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp pkt2(%{phase: :casting, counter: c} = tech, player) do
    # Wait the cast out (the bolt spawns as the hold anim begins),
    # then run the steer plan.
    if int(player.action) == 0x167 or c >= 30 do
      plan =
        Keyword.get(tech.opts, :steer, [
          {1.0, 0.5, 15},
          {0.5, 0.0, 15},
          {0.0, 0.5, 15},
          {0.5, 1.0, 40}
        ])

      pkt2(%{tech | phase: :steering, counter: 0, aux: plan}, player)
    else
      # Neutral the stick during the cast — the held direction at the
      # bolt's spawn frame AIMS it (a latched up-tilt spawned the bolt
      # low inside ness, where it died instantly).
      {:cont, %{tech | counter: c + 1}, [{:release, :b}, {:tilt, :main, 0.5, 0.0}]}
    end
  end

  defp pkt2(%{phase: :steering, aux: plan, counter: c} = tech, player) do
    cond do
      # The bolt connected: ness takes the PKT2 launch (hitlag on
      # himself marks the contact).
      player.hitlag_left > 0 ->
        {:cont, %{tech | phase: :launched, counter: 0}, [{:tilt, :main, 0.5, 0.5}]}

      plan == [] ->
        {:done, tech, [:release_all]}

      true ->
        [{x, y, frames} | rest] = plan

        if c + 1 >= frames do
          {:cont, %{tech | aux: rest, counter: 0}, [{:tilt, :main, x, y}]}
        else
          {:cont, %{tech | counter: c + 1}, [{:tilt, :main, x, y}]}
        end
    end
  end

  defp pkt2(%{phase: :launched, counter: c} = tech, player) do
    cond do
      c > 10 and player.on_ground and int(player.action) < 0x40 -> {:done, tech, [:release_all]}
      c >= 120 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Walljump (the 8 walljumpers): the wall band is only the ~15 units
  # right under the lip (mapped live: FD and PS undersides recede
  # inward faster than air drift converges, and a ledge hang sits ~2
  # units OUTSIDE the plane), so the entry is from ABOVE — hop out
  # barely past the lip, hold hard INTO the wall on the way down, and
  # detect contact as "x stopped moving while falling". Pin a couple
  # of frames, then flick AWAY. `direction:` picks the side,
  # `edge_x:` the lip's |x| (85.57 FD / 87.75 PS), `dive_y:` the
  # bail-out floor, `pin_frames:` frames of contact before the flick.
  defp walljump(%{phase: :init} = tech, %{on_ground: false} = player) do
    cond do
      int(player.action) == @edge_hanging ->
        # The RELIABLE entry: a hanging body already rests on the wall
        # contact plane (mapped live on FD and PS). Release with a
        # SOFT down tap — past the drop threshold, short of the
        # fastfall one — so the first falling frames stay inside the
        # wall band.
        {:cont, %{tech | phase: :release, counter: 0}, [{:tilt, :main, 0.5, 0.35}]}

      # Already airborne just outside the lip (e.g. handed over from a
      # wavedash slide-off — the tightest entry): hug straight away.
      abs(player.position.x) > Keyword.get(tech.opts, :edge_x, 85.57) and
          player.position.y < 2.0 ->
        into = if ledge_right?(tech), do: 0.05, else: 0.95
        {:cont, %{tech | phase: :hugging, counter: 0, aux: nil}, [{:tilt, :main, into, 0.5}]}

      true ->
        {:cont, tech, []}
    end
  end

  defp walljump(%{phase: :release, counter: c} = tech, player) do
    cond do
      int(player.action) != @edge_hanging ->
        # Falling on the plane: press gently in, then flick within
        # the first frames (the band is only ~15 units tall).
        into = if ledge_right?(tech), do: 0.3, else: 0.7
        {:cont, %{tech | phase: :pinning, counter: 0}, [{:tilt, :main, into, 0.4}]}

      c >= 30 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:tilt, :main, 0.5, 0.35}]}
    end
  end

  defp walljump(%{phase: :init} = tech, %{on_ground: true} = player) do
    if int(player.action) == @standing do
      x = if ledge_right?(tech), do: 0.62, else: 0.38
      {:cont, %{tech | phase: :hop}, [{:tilt, :main, x, 0.5}, {:press, :y}]}
    else
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  defp walljump(%{phase: :hop} = tech, player) do
    if player.on_ground do
      {:cont, tech, [{:release, :y}]}
    else
      x = if ledge_right?(tech), do: 0.62, else: 0.38
      {:cont, %{tech | phase: :out, counter: 0}, [{:release, :y}, {:tilt, :main, x, 0.5}]}
    end
  end

  defp walljump(%{phase: :out, counter: c} = tech, player) do
    cond do
      # `out_frames:` of outward drift, then hold hard IN — the frame
      # quantization is the dial that sets how tightly the descent
      # crosses back over the lip (sweep it).
      c >= Keyword.get(tech.opts, :out_frames, 6) ->
        into = if ledge_right?(tech), do: 0.05, else: 0.95
        {:cont, %{tech | phase: :hugging, counter: 0, aux: nil}, [{:tilt, :main, into, 0.5}]}

      player.on_ground ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp walljump(%{phase: :hugging, counter: c, aux: prev} = tech, player) do
    x = player.position.x
    falling = player.speed_y_self < 0

    cond do
      int(player.action) in [@edge_catch, @edge_hanging] ->
        {:done, tech, [:release_all]}

      player.on_ground ->
        {:done, tech, [:release_all]}

      # Contact: the in-drift stopped moving us while falling, NEAR
      # the wall plane (the near-check rejects the outward-speed
      # zero-crossing at the top of the excursion).
      c >= 2 and falling and prev != nil and abs(x - prev) < 0.02 and
          abs(x) < Keyword.get(tech.opts, :edge_x, 85.57) + 2.0 ->
        {:cont, %{tech | phase: :pinning, counter: 0}, []}

      player.position.y < Keyword.get(tech.opts, :dive_y, -40.0) ->
        {:done, tech, [:release_all]}

      c >= 150 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1, aux: x}, []}
    end
  end

  defp walljump(%{phase: :pinning, counter: c} = tech, _player) do
    if c >= Keyword.get(tech.opts, :pin_frames, 2) do
      # The flick: smash the stick AWAY from the wall.
      away = if ledge_right?(tech), do: 1.0, else: 0.0
      {:cont, %{tech | phase: :flicking, counter: 0}, [{:tilt, :main, away, 0.5}]}
    else
      {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp walljump(%{phase: :flicking, counter: c} = tech, player) do
    cond do
      # Upward velocity with no button pressed: the walljump came out.
      player.speed_y_self > 0.5 ->
        {:done, tech, [:release_all]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Walltech: ONE L press (never pulsed — early = 40f lockout) when a
  # damage-state character is within `margin:` units of the wall PLANE
  # at `wall_x:` (85.57 FD). Techable characters are OUTSIDE the
  # stage, so "into the wall" means toward the stage — held on BOTH
  # sticks: the c-stick's ASDI shifts the body INTO the wall when
  # hitlag resolves, manufacturing the wall impact the tech needs
  # (the sideways Amsah tech). Arms during hitlag (the ASDI must be
  # parked before resolution) or on the way down.
  defp walltech(%{phase: :init} = tech, player) do
    wall_x = Keyword.get(tech.opts, :wall_x, 85.57)
    margin = Keyword.get(tech.opts, :margin, 6.0)

    armed? =
      not player.on_ground and MapSet.member?(@hitstun_air, int(player.action)) and
        (player.hitlag_left > 0 or player.speed_y_self + player.speed_y_attack < 0) and
        abs(abs(player.position.x) - wall_x) < margin

    if armed? do
      x = if player.position.x > 0, do: 0.0, else: 1.0

      {:cont, %{tech | phase: :pressed, counter: 0},
       [{:press, :l}, {:tilt, :main, x, 0.5}, {:tilt, :c, x, 0.5}]}
    else
      {:cont, tech, []}
    end
  end

  defp walltech(%{phase: :pressed, counter: c} = tech, player) do
    cond do
      int(player.action) in [@wall_tech, @wall_tech_jump] -> {:done, tech, [:release_all]}
      c >= 40 -> {:done, tech, [:release_all]}
      c >= 2 -> {:cont, %{tech | counter: c + 1}, [{:release, :l}]}
      true -> {:cont, %{tech | counter: c + 1}, []}
    end
  end

  # Wobbling: from the desync grab (Popo holds, Nana free), down+A on
  # a metronome — Popo pummels while Nana (6 frames late) dtilts, and
  # the alternation keeps the victim in permanent hitstun. `interval:`
  # frames between presses (sweep ~20-32), `reps:` total presses.
  defp wobble(%{phase: :init} = tech, %{on_ground: true}),
    do: {:cont, %{tech | phase: :grabbing, counter: 0}, [{:press, :z}]}

  defp wobble(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp wobble(%{phase: :grabbing, counter: c} = tech, player) do
    # Same arming as :ics_desync: Popo's grab connected and Nana's
    # 6-frame-late whiff has ended. The down-tilt must be PARKED as
    # soon as the grab connects (CatchPull) — a fresh down EDGE in
    # CatchWait is a down-THROW (stick throws fire on edges, never on
    # holds: the thunders finding, inverted).
    a = int(player.action)
    nana_ready? = player.nana == nil or int(player.nana.action) < 0x40

    cond do
      a in [0xD5, 0xD8] and nana_ready? ->
        reps = Keyword.get(tech.opts, :reps, 8)
        {:cont, %{tech | phase: :wobbling, counter: 0, aux: reps}, [{:tilt, :main, 0.5, 0.0}]}

      c >= 90 ->
        {:done, tech, [:release_all]}

      a in 0xD4..0xD8 ->
        {:cont, %{tech | counter: c + 1}, [{:release, :z}, {:tilt, :main, 0.5, 0.0}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :z}]}
    end
  end

  defp wobble(%{phase: :wobbling, counter: c, aux: reps} = tech, player) do
    interval = Keyword.get(tech.opts, :interval, 24)

    cond do
      # The victim escaped (no grab-family action on us): stop.
      int(player.action) not in [0xD5, 0xD8, 0xD9] ->
        {:done, tech, [:release_all]}

      reps <= 0 ->
        {:done, tech, [:release_all]}

      c == 0 ->
        {:cont, %{tech | counter: c + 1}, [{:press, :a}, {:tilt, :main, 0.5, 0.0}]}

      c == 2 ->
        {:cont, %{tech | counter: c + 1}, [{:release, :a}]}

      c >= interval ->
        {:cont, %{tech | counter: 0, aux: reps - 1}, []}

      true ->
        {:cont, %{tech | counter: c + 1}, []}
    end
  end

  ## ------------------------------------------------------------------
  ## Round 7: the feasible-unpicked pool
  ## ------------------------------------------------------------------

  # Fox/Falco Illusion/Phantasm (side-B). Fox rides actions 0x15E-0x160,
  # falco 0x15B-0x15D (mapped live). `shorten_frame:` presses B again that
  # many frames into the dash — Melee's shorten, which has its own
  # action id (fox_illusion_shortened 0x160).
  defp illusion(%{phase: :init} = tech, %{on_ground: true} = player) do
    if int(player.action) == @standing do
      x = if dir_right?(tech), do: 1.0, else: 0.0
      {:cont, %{tech | phase: :starting, counter: 0}, [{:tilt, :main, x, 0.5}, {:press, :b}]}
    else
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  defp illusion(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp illusion(%{phase: :starting, counter: c} = tech, player) do
    cond do
      int(player.action) in [0x15B, 0x15C, 0x15E, 0x15F] ->
        illusion(%{tech | phase: :dashing, counter: 0}, player)

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}]}
    end
  end

  defp illusion(%{phase: :dashing, counter: c} = tech, player) do
    shorten = Keyword.get(tech.opts, :shorten_frame)
    a = int(player.action)

    cond do
      a not in [0x15B, 0x15C, 0x15D, 0x15E, 0x15F, 0x160] and c > 3 ->
        {:done, tech, [:release_all]}

      # :pulse hits every possible shorten window (diagnostic mode).
      shorten == :pulse ->
        cmd = if rem(c, 2) == 0, do: [{:press, :b}], else: [{:release, :b}]
        {:cont, %{tech | counter: c + 1}, cmd}

      is_integer(shorten) and c == shorten ->
        {:cont, %{tech | counter: c + 1}, [{:press, :b}]}

      is_integer(shorten) and c == shorten + 2 ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}]}

      c >= 90 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}]}
    end
  end

  # Haxdash: fastfall-free ledge release, instant double jump back in
  # — regrabs the ledge with the facing never turning around, and the
  # regrab refreshes the intangibility. `dj_delay:` frames between the
  # release and the jump (sweep 1-4).
  defp haxdash(%{phase: :init} = tech, player) do
    if int(player.action) == @edge_hanging do
      {:cont, %{tech | phase: :releasing, counter: 0}, [{:tilt, :main, 0.5, 0.35}]}
    else
      {:cont, tech, []}
    end
  end

  defp haxdash(%{phase: :releasing, counter: c} = tech, player) do
    cond do
      int(player.action) != @edge_hanging ->
        {:cont, %{tech | phase: :dropping, counter: 0}, [{:tilt, :main, 0.5, 0.5}]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:tilt, :main, 0.5, 0.35}]}
    end
  end

  defp haxdash(%{phase: :dropping, counter: c} = tech, _player) do
    if c >= Keyword.get(tech.opts, :dj_delay, 2) do
      {:cont, %{tech | phase: :jumping, counter: 0}, [{:press, :x}]}
    else
      {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp haxdash(%{phase: :jumping, counter: c} = tech, player) do
    cond do
      int(player.action) in [@edge_catch, @edge_hanging] ->
        {:done, tech, [:release_all]}

      c >= 60 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :x}]}
    end
  end

  # Ledgestall: release the hang, then UP-B back into the ledge — the
  # regrab refreshes intangibility. Marth's sweetspot is a SNAP in the
  # up-B's first frames and needs a shallow start, so the release is
  # an AWAY tap (a down-release pre-drops ~24 units before the fall
  # even registers — measured). `delay:` frames of fall before the
  # up-B.
  defp ledgestall(%{phase: :init} = tech, player) do
    away = if ledge_right?(tech), do: 0.95, else: 0.05

    if int(player.action) == @edge_hanging do
      {:cont, %{tech | phase: :releasing, counter: 0}, [{:tilt, :main, away, 0.5}]}
    else
      {:cont, tech, []}
    end
  end

  defp ledgestall(%{phase: :releasing, counter: c} = tech, player) do
    away = if ledge_right?(tech), do: 0.95, else: 0.05

    cond do
      int(player.action) != @edge_hanging ->
        {:cont, %{tech | phase: :falling, counter: 0}, [{:tilt, :main, 0.5, 0.5}]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:tilt, :main, away, 0.5}]}
    end
  end

  defp ledgestall(%{phase: :falling, counter: c} = tech, _player) do
    # The hang releases ~24 units deep (marth) — too low for the up-B
    # snap — so DOUBLE JUMP first, then up-B near ledge height.
    if c >= Keyword.get(tech.opts, :delay, 2) do
      {:cont, %{tech | phase: :djing, counter: 0}, [{:press, :x}]}
    else
      {:cont, %{tech | counter: c + 1}, []}
    end
  end

  defp ledgestall(%{phase: :djing, counter: c} = tech, _player) do
    if c >= Keyword.get(tech.opts, :up_b_delay, 6) do
      {:cont, %{tech | phase: :recovering, counter: 0},
       [{:release, :x}, {:tilt, :main, 0.5, 1.0}, {:press, :b}]}
    else
      {:cont, %{tech | counter: c + 1}, [{:release, :x}]}
    end
  end

  defp ledgestall(%{phase: :recovering, counter: c} = tech, player) do
    # B-REVERSE the slash on its first frames (stick away from the
    # stage): marth's up-B sweetspot wants the ledge BEHIND him — a
    # forward-facing rise sails past the ledge without grabbing
    # (measured at x 88.6, y -7..-19: no snap, ever).
    away = if ledge_right?(tech), do: 0.95, else: 0.05

    cond do
      int(player.action) in [@edge_catch, @edge_hanging] ->
        {:done, tech, [:release_all]}

      c >= 90 ->
        {:done, tech, [:release_all]}

      c < 2 ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}, {:tilt, :main, away, 0.5}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}, {:tilt, :main, 0.5, 0.5}]}
    end
  end

  # Falco ledgehop double laser: release the hang, double jump up and
  # in over the lip, pulse B on the way — two lasers before landing.
  defp ledgehop_laser(%{phase: :init} = tech, player) do
    if int(player.action) == @edge_hanging do
      {:cont, %{tech | phase: :releasing, counter: 0}, [{:tilt, :main, 0.5, 0.35}]}
    else
      {:cont, tech, []}
    end
  end

  defp ledgehop_laser(%{phase: :releasing, counter: c} = tech, player) do
    cond do
      int(player.action) != @edge_hanging ->
        {:cont, %{tech | phase: :hopping, counter: 0}, [{:tilt, :main, 0.5, 0.5}]}

      c >= 20 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:tilt, :main, 0.5, 0.35}]}
    end
  end

  defp ledgehop_laser(%{phase: :hopping, counter: c} = tech, _player) do
    into = if ledge_right?(tech), do: 0.25, else: 0.75

    cond do
      c == 0 ->
        {:cont, %{tech | counter: c + 1}, [{:press, :x}, {:tilt, :main, into, 0.5}]}

      c >= Keyword.get(tech.opts, :fire_delay, 10) ->
        {:cont, %{tech | phase: :firing, counter: 0}, [{:release, :x}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :x}]}
    end
  end

  defp ledgehop_laser(%{phase: :firing, counter: c} = tech, player) do
    cond do
      player.on_ground ->
        {:done, tech, [:release_all]}

      c >= 90 ->
        {:done, tech, [:release_all]}

      rem(c, 2) == 0 ->
        {:cont, %{tech | counter: c + 1}, [{:press, :b}]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :b}]}
    end
  end

  # Pivot grab: the empty pivot's one-frame opposite flick, with Z on
  # the flick — a standing grab facing the NEW way, no slide.
  defp pivot_grab(%{phase: :init} = tech, %{on_ground: true}) do
    x = if dir_right?(tech), do: 1.0, else: 0.0
    dash = Keyword.get(tech.opts, :dash_frames, 5)
    {:cont, %{tech | phase: :dashing, counter: dash}, [{:tilt, :main, x, 0.5}]}
  end

  defp pivot_grab(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp pivot_grab(%{phase: :dashing, counter: c} = tech, _player) when c > 1,
    do: {:cont, %{tech | counter: c - 1}, []}

  defp pivot_grab(%{phase: :dashing} = tech, _player) do
    x = if dir_right?(tech), do: 0.0, else: 1.0
    {:cont, %{tech | phase: :flick}, [{:tilt, :main, x, 0.5}]}
  end

  defp pivot_grab(%{phase: :flick} = tech, _player),
    do: {:cont, %{tech | phase: :grabbing, counter: 0}, [{:tilt, :main, 0.5, 0.5}, {:press, :z}]}

  defp pivot_grab(%{phase: :grabbing, counter: c} = tech, player) do
    cond do
      int(player.action) in @grab_actions -> {:done, tech, [:release_all]}
      c >= 20 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, [{:release, :z}]}
    end
  end

  # Boost grab: dash attack cancelled into a grab (Z right after the
  # A) — the grab keeps the dash attack's slide, reaching farther than
  # any other grab.
  defp boost_grab(%{phase: :init} = tech, %{on_ground: true} = player) do
    if int(player.action) == @standing do
      x = if dir_right?(tech), do: 1.0, else: 0.0
      dash = Keyword.get(tech.opts, :dash_frames, 5)
      {:cont, %{tech | phase: :dashing, counter: dash}, [{:tilt, :main, x, 0.5}]}
    else
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]}
    end
  end

  defp boost_grab(%{phase: :init} = tech, _player), do: {:cont, tech, []}

  defp boost_grab(%{phase: :dashing, counter: c} = tech, _player) when c > 1,
    do: {:cont, %{tech | counter: c - 1}, []}

  defp boost_grab(%{phase: :dashing} = tech, _player),
    do: {:cont, %{tech | phase: :attacking, counter: 0}, [{:press, :a}]}

  defp boost_grab(%{phase: :attacking, counter: c} = tech, player) do
    cond do
      int(player.action) == 0x32 or c >= Keyword.get(tech.opts, :z_delay, 2) ->
        {:cont, %{tech | phase: :grabbing, counter: 0}, [{:release, :a}, {:press, :z}]}

      c >= 15 ->
        {:done, tech, [:release_all]}

      true ->
        {:cont, %{tech | counter: c + 1}, [{:release, :a}]}
    end
  end

  defp boost_grab(%{phase: :grabbing, counter: c} = tech, player) do
    cond do
      int(player.action) in @grab_actions -> {:done, tech, [:release_all]}
      c >= 25 -> {:done, tech, [:release_all]}
      true -> {:cont, %{tech | counter: c + 1}, [{:release, :z}]}
    end
  end

  defp int(a) when is_integer(a), do: a
  defp int(a) when is_number(a), do: trunc(a)
  defp int(_), do: -1

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
