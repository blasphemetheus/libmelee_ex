defmodule Melee.Position do
  @moduledoc """
  An (x, y) coordinate pair. Used for positions, speeds, and cursors.

  Mirrors libmelee's `Position` dataclass (also aliased there as `Speed`
  and `Cursor`).
  """

  @type t :: %__MODULE__{x: float(), y: float()}

  defstruct x: 0.0, y: 0.0

  @doc "Build a position from x and y."
  @spec new(number(), number()) :: t()
  def new(x, y), do: %__MODULE__{x: x * 1.0, y: y * 1.0}
end

defmodule Melee.ECB do
  @moduledoc """
  Environmental collision box: a diamond defined by four points.

  Mirrors libmelee's `ECB` dataclass.
  """

  alias Melee.Position

  @type t :: %__MODULE__{
          top: Position.t(),
          bottom: Position.t(),
          left: Position.t(),
          right: Position.t()
        }

  defstruct top: %Position{}, bottom: %Position{}, left: %Position{}, right: %Position{}
end

defmodule Melee.FoDPlatforms do
  @moduledoc """
  Heights of the two side platforms on Fountain of Dreams.

  Initial values match libmelee's (found by experimentation, extrapolated
  backwards from when the platforms start moving).
  """

  @type t :: %__MODULE__{left: float(), right: float()}

  defstruct left: 20.0, right: 28.0
end

defmodule Melee.StadiumTransformation do
  @moduledoc """
  Current Pokemon Stadium transformation state.

  `event` and `type` hold the raw Slippi values; see
  the SPEC's stadium-transformation section. Event values: 0 finished,
  2 initialize, 3 on_monitor, 4 previous_receding, 5 new_rising, 6 finalize.
  Type values: 3 fire, 4 grass, 5 normal, 6 rock, 9 water.
  """

  @type t :: %__MODULE__{event: integer(), type: integer()}

  # Defaults mirror libmelee: FINISHED / NORMAL
  defstruct event: 0, type: 5
end

defmodule Melee.GameState do
  @moduledoc """
  A single snapshot in time of a running game of Melee — everything needed
  to make a gameplay decision.

  Mirrors libmelee's `GameState`. Enum-valued fields (`stage`, `menu_state`,
  `submenu`) store the raw integer wire values; use `Melee.Enums.*` modules
  to convert to and from atoms.
  """

  alias Melee.{FoDPlatforms, PlayerState, Projectile, StadiumTransformation}

  @type port_number :: 1..4

  @type t :: %__MODULE__{
          frame: integer(),
          stage: integer(),
          whispy: integer() | nil,
          fod_platforms: FoDPlatforms.t() | nil,
          stadium_transformation: StadiumTransformation.t() | nil,
          menu_state: integer(),
          submenu: integer(),
          players: %{port_number() => PlayerState.t()},
          projectiles: [Projectile.t()],
          ready_to_start: boolean(),
          is_teams: boolean(),
          distance: float(),
          menu_selection: integer(),
          startAt: String.t(),
          playedOn: String.t(),
          consoleNick: String.t(),
          custom: map()
        }

  # Defaults mirror libmelee: frame -10000, FINAL_DESTINATION (0x19),
  # menu_state IN_GAME (2), submenu UNKNOWN_SUBMENU (0xFF).
  defstruct frame: -10_000,
            stage: 0x19,
            whispy: nil,
            fod_platforms: nil,
            stadium_transformation: nil,
            menu_state: 2,
            submenu: 0xFF,
            players: %{},
            projectiles: [],
            ready_to_start: false,
            is_teams: false,
            distance: 0.0,
            menu_selection: 0,
            startAt: "",
            playedOn: "",
            consoleNick: "",
            custom: %{}

  @in_game 2
  @sudden_death 3

  @doc """
  Is the game in an active game state (in-game or sudden death), rather
  than in menus?
  """
  @spec in_game?(t()) :: boolean()
  def in_game?(%__MODULE__{menu_state: menu_state}),
    do: menu_state in [@in_game, @sudden_death]

  @doc "Get the player on the given controller port, or nil."
  @spec player(t(), port_number()) :: PlayerState.t() | nil
  def player(%__MODULE__{players: players}, port) when is_integer(port),
    do: Map.get(players, port)

  @doc """
  Autodiscover which port the given character/costume pair is on.

  Slippi Online assigns a random port when playing online. Returns the
  port (1-4) if exactly one player matches, or 0 if none or several do.

  Mirrors libmelee's `port_detector/3`.
  """
  @spec port_detector(t(), integer(), integer()) :: 0 | port_number()
  def port_detector(%__MODULE__{players: players}, character, costume) do
    Enum.reduce_while(players, 0, fn {port, player}, detected ->
      case {player.character == character and player.costume == costume, detected} do
        {false, _} -> {:cont, detected}
        {true, 0} -> {:cont, port}
        {true, _} -> {:halt, 0}
      end
    end)
  end
end

defmodule Melee.PlayerState do
  @moduledoc """
  The state of a single player (or of Nana, for Ice Climbers).

  Mirrors libmelee's `PlayerState`. Enum-valued fields (`character`,
  `character_selected`, `action`, `controller_status`) store raw integer
  wire values; unknown values stay as their integers rather than raising.
  """

  alias Melee.{ControllerState, ECB, Position}

  @type t :: %__MODULE__{
          character: integer(),
          character_selected: integer(),
          position: Position.t(),
          percent: float(),
          shield_strength: float(),
          is_powershield: boolean(),
          stock: non_neg_integer(),
          facing: boolean(),
          action: integer(),
          action_frame: integer(),
          invulnerable: boolean(),
          invulnerability_left: integer(),
          hitlag_left: integer(),
          hitstun_frames_left: integer(),
          jumps_left: integer(),
          on_ground: boolean(),
          speed_air_x_self: float(),
          speed_y_self: float(),
          speed_x_attack: float(),
          speed_y_attack: float(),
          speed_ground_x_self: float(),
          nana: t() | nil,
          cursor: Position.t(),
          coin_down: boolean(),
          controller_status: integer(),
          off_stage: boolean(),
          iasa: integer(),
          moonwalkwarning: boolean(),
          controller_state: ControllerState.t(),
          ecb: ECB.t(),
          costume: integer(),
          cpu_level: integer(),
          is_holding_cpu_slider: boolean(),
          nametag: String.t(),
          nickName: String.t(),
          connectCode: String.t(),
          displayName: String.t(),
          team_id: integer()
        }

  # Defaults mirror libmelee: UNKNOWN_CHARACTER (0xFF), action -1 (unknown),
  # CONTROLLER_UNPLUGGED (3), shield 60.0, facing right.
  defstruct character: 0xFF,
            character_selected: 0xFF,
            position: %Position{},
            percent: 0.0,
            shield_strength: 60.0,
            is_powershield: false,
            stock: 0,
            facing: true,
            action: -1,
            action_frame: 0,
            invulnerable: false,
            invulnerability_left: 0,
            hitlag_left: 0,
            hitstun_frames_left: 0,
            jumps_left: 0,
            on_ground: true,
            speed_air_x_self: 0.0,
            speed_y_self: 0.0,
            speed_x_attack: 0.0,
            speed_y_attack: 0.0,
            speed_ground_x_self: 0.0,
            nana: nil,
            cursor: %Position{},
            coin_down: false,
            controller_status: 3,
            off_stage: false,
            iasa: 0,
            moonwalkwarning: false,
            controller_state: %ControllerState{},
            ecb: %ECB{},
            costume: 0,
            cpu_level: 0,
            is_holding_cpu_slider: false,
            nametag: "",
            nickName: "",
            connectCode: "",
            displayName: "",
            team_id: 0
end

defmodule Melee.Projectile do
  @moduledoc """
  The state of a projectile (items, lasers, turnips, ...).

  Mirrors libmelee's `Projectile`. `type` stores the raw item type id;
  unknown types stay as their integer value.
  """

  alias Melee.Position

  @type t :: %__MODULE__{
          position: Position.t(),
          speed: Position.t(),
          owner: integer(),
          type: integer(),
          expiration_frames: float(),
          subtype: integer(),
          spawn_id: non_neg_integer()
        }

  defstruct position: %Position{},
            speed: %Position{},
            owner: -1,
            type: 0xFFFF,
            expiration_frames: 0.0,
            subtype: 0,
            spawn_id: 0
end
