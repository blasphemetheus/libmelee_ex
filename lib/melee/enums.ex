defmodule Melee.Enums do
  @moduledoc """
  Enum values for various Melee objects.

  Port of libmelee's `enums.py`. Game-state structs elsewhere in this library
  store the RAW INTEGER wire values; these modules provide atom <-> integer
  conversion for ergonomics. Every integer enum module exposes:

    * `from_id/1` — integer to atom, `{:unknown, id}` fallback (never raises)
    * `to_id/1` — atom (or `{:unknown, id}`) back to integer
    * `name/1` — human-readable name for an integer ID
    * `entries/0` — all canonical `{atom, id}` pairs

  The large `Action` and `ProjectileType` enums live in their own files under
  `lib/melee/enums/`.
  """
end

defmodule Melee.Enums.Stage do
  @moduledoc """
  A VS-mode stage (raw in-game stage IDs).

  Also carries the "external" stage-select / Slippi start-report IDs via
  `from_external/1` and `to_external/1` (Python's `to_internal_stage`).

  ## Examples

      iex> Melee.Enums.Stage.from_id(0x19)
      :final_destination

      iex> Melee.Enums.Stage.to_id(:battlefield)
      0x18

      iex> Melee.Enums.Stage.from_id(0x42)
      {:unknown, 0x42}

      iex> Melee.Enums.Stage.from_external(0x03)
      :pokemon_stadium
  """
  require Melee.Enums.Builder

  Melee.Enums.Builder.int_enum(
    no_stage: 0,
    final_destination: 0x19,
    battlefield: 0x18,
    pokemon_stadium: 0x12,
    dreamland: 0x1A,
    fountain_of_dreams: 0x8,
    yoshis_story: 0x6,
    # not technically a stage, but it's useful to call it one
    random_stage: 0x1D
  )

  @external_to_stage %{
    0x03 => :pokemon_stadium,
    0x08 => :yoshis_story,
    0x02 => :fountain_of_dreams,
    0x1F => :battlefield,
    0x20 => :final_destination,
    0x1C => :dreamland
  }
  @stage_to_external Map.new(@external_to_stage, fn {k, v} -> {v, k} end)

  @doc """
  Converts an external (stage select screen / Slippi) stage ID to a stage atom.

  Unknown external IDs return `:no_stage`, matching Python's
  `to_internal_stage`.
  """
  @spec from_external(integer()) :: atom()
  def from_external(external_id) when is_integer(external_id) do
    Map.get(@external_to_stage, external_id, :no_stage)
  end

  @doc """
  Returns true if the integer is a known external (stage select / Slippi)
  stage ID.

  ## Examples

      iex> Melee.Enums.Stage.valid_external?(0x20)
      true

      iex> Melee.Enums.Stage.valid_external?(0x42)
      false
  """
  @spec valid_external?(integer()) :: boolean()
  def valid_external?(id), do: is_integer(id) and Map.has_key?(@external_to_stage, id)

  @doc """
  Converts a stage atom to its external (stage select screen / Slippi) ID.

  Returns `nil` for stages with no external ID (`:no_stage`, `:random_stage`).
  """
  @spec to_external(atom()) :: integer() | nil
  def to_external(stage) when is_atom(stage), do: Map.get(@stage_to_external, stage)
end

defmodule Melee.Enums.Menu do
  @moduledoc """
  A primary menu scene the game can be in.

  ## Examples

      iex> Melee.Enums.Menu.from_id(2)
      :in_game

      iex> Melee.Enums.Menu.to_id(:character_select)
      0
  """
  require Melee.Enums.Builder

  Melee.Enums.Builder.int_enum(
    character_select: 0,
    stage_select: 1,
    in_game: 2,
    sudden_death: 3,
    postgame_scores: 4,
    main_menu: 5,
    slippi_online_css: 6,
    press_start: 7,
    unknown_menu: 0xFF
  )
end

defmodule Melee.Enums.SubMenu do
  @moduledoc """
  Sub-menu of a primary menu.

  ## Examples

      iex> Melee.Enums.SubMenu.from_id(8)
      :online_play_submenu

      iex> Melee.Enums.SubMenu.to_id(:name_entry_submenu)
      18
  """
  require Melee.Enums.Builder

  Melee.Enums.Builder.int_enum(
    main_menu_submenu: 0,
    onep_mode_submenu: 1,
    vs_mode_submenu: 2,
    trophies_submenu: 3,
    option_submenu: 4,
    data_submenu: 5,
    regular_match_submenu: 6,
    event_match_submenu: 7,
    online_play_submenu: 8,
    stadium_submenu: 9,
    special_melee_submenu: 12,
    custom_rules_submenu: 13,
    name_entry_submenu: 18,
    rumble_submenu: 19,
    sound_submenu: 20,
    screen_display_submenu: 21,
    language_select_submenu: 23,
    erase_data_submenu: 24,
    multiman_melee_submenu: 33,
    online_css: 0xFE,
    unknown_submenu: 0xFF
  )
end

defmodule Melee.Enums.ControllerStatus do
  @moduledoc """
  One of three states a controller can be in during character select.

  ## Examples

      iex> Melee.Enums.ControllerStatus.from_id(0)
      :controller_human

      iex> Melee.Enums.ControllerStatus.to_id(:controller_unplugged)
      3
  """
  require Melee.Enums.Builder

  Melee.Enums.Builder.int_enum(
    controller_human: 0,
    controller_cpu: 1,
    controller_unplugged: 3
  )
end

defmodule Melee.Enums.ControllerType do
  @moduledoc """
  Types a controller can be in the Dolphin config.

  Named pipe input is considered "standard" input by Dolphin. Python's enum
  values are the Dolphin config strings, so this module converts atoms to and
  from those strings rather than integers.

  ## Examples

      iex> Melee.Enums.ControllerType.to_config_string(:standard)
      "6"

      iex> Melee.Enums.ControllerType.from_config_string("12")
      :gcn_adapter
  """

  @entries [standard: "6", gcn_adapter: "12", unplugged: "0"]
  @from_string Map.new(@entries, fn {name, s} -> {s, name} end)
  @to_string Map.new(@entries)

  @doc "Returns all `{atom, config_string}` entries."
  @spec entries() :: [{atom(), String.t()}]
  def entries, do: @entries

  @doc "Converts a controller type atom to its Dolphin config string."
  @spec to_config_string(atom()) :: String.t()
  def to_config_string(type) when is_atom(type), do: Map.fetch!(@to_string, type)

  @doc """
  Converts a Dolphin config string to a controller type atom.

  Unknown strings return `{:unknown, string}`.
  """
  @spec from_config_string(String.t()) :: atom() | {:unknown, String.t()}
  def from_config_string(s) when is_binary(s), do: Map.get(@from_string, s, {:unknown, s})
end

defmodule Melee.Enums.AttackState do
  @moduledoc """
  The phases an attack can be in.

  ## Examples

      iex> Melee.Enums.AttackState.from_id(1)
      :attacking

      iex> Melee.Enums.AttackState.to_id(:not_attacking)
      3
  """
  require Melee.Enums.Builder

  Melee.Enums.Builder.int_enum(
    windup: 0,
    attacking: 1,
    cooldown: 2,
    not_attacking: 3
  )
end

defmodule Melee.Enums.Character do
  @moduledoc """
  A Melee character ID.

  Numeric values are the "internal" IDs used in-game. The character select
  screen uses a different "external" ID space; convert with `to_internal/1`
  (external integer -> atom) and `from_internal/1` (atom -> external integer),
  matching Python's functions of the same names.

  ## Examples

      iex> Melee.Enums.Character.from_id(0x01)
      :fox

      iex> Melee.Enums.Character.to_id(:marth)
      0x12

      iex> Melee.Enums.Character.to_internal(0x0A)
      :fox

      iex> Melee.Enums.Character.from_internal(:fox)
      0x0A
  """
  require Melee.Enums.Builder

  Melee.Enums.Builder.int_enum(
    mario: 0x00,
    fox: 0x01,
    cptfalcon: 0x02,
    dk: 0x03,
    kirby: 0x04,
    bowser: 0x05,
    link: 0x06,
    sheik: 0x07,
    ness: 0x08,
    peach: 0x09,
    popo: 0x0A,
    nana: 0x0B,
    pikachu: 0x0C,
    samus: 0x0D,
    yoshi: 0x0E,
    jigglypuff: 0x0F,
    mewtwo: 0x10,
    luigi: 0x11,
    marth: 0x12,
    zelda: 0x13,
    ylink: 0x14,
    doc: 0x15,
    falco: 0x16,
    pichu: 0x17,
    gameandwatch: 0x18,
    ganondorf: 0x19,
    roy: 0x1A,
    wireframe_male: 0x1D,
    wireframe_female: 0x1E,
    giga_bowser: 0x1F,
    sandbag: 0x20,
    unknown_character: 0xFF
  )

  @external_to_character %{
    0x00 => :doc,
    0x01 => :mario,
    0x02 => :luigi,
    0x03 => :bowser,
    0x04 => :peach,
    0x05 => :yoshi,
    0x06 => :dk,
    0x07 => :cptfalcon,
    0x08 => :ganondorf,
    0x09 => :falco,
    0x0A => :fox,
    0x0B => :ness,
    0x0C => :popo,
    0x0D => :kirby,
    0x0E => :samus,
    0x0F => :zelda,
    0x10 => :link,
    0x11 => :ylink,
    0x12 => :pichu,
    0x13 => :pikachu,
    0x14 => :jigglypuff,
    0x15 => :mewtwo,
    0x16 => :gameandwatch,
    0x17 => :marth,
    0x18 => :roy
  }
  @character_to_external Map.new(@external_to_character, fn {k, v} -> {v, k} end)

  @doc """
  Converts a character select-screen (external) ID to an internal character
  atom. Unknown IDs return `:unknown_character`, matching Python.
  """
  @spec to_internal(integer()) :: atom()
  def to_internal(char_id) when is_integer(char_id) do
    Map.get(@external_to_character, char_id, :unknown_character)
  end

  @doc """
  Converts a character select-screen (external) ID directly to the raw
  internal integer ID, or `nil` for unknown/nil input.

  Convenience for game-state structs, which store raw integers.

  ## Examples

      iex> Melee.Enums.Character.from_css(0x0A)
      0x01

      iex> Melee.Enums.Character.from_css(0x99)
      nil
  """
  @spec from_css(integer() | nil) :: integer() | nil
  def from_css(nil), do: nil

  def from_css(css_id) when is_integer(css_id) do
    case Map.get(@external_to_character, css_id) do
      nil -> nil
      atom -> to_id(atom)
    end
  end

  @doc """
  Converts a character atom to its character select-screen (external) ID.
  Characters not on the select screen return `0xFF`, matching Python.
  """
  @spec from_internal(atom()) :: integer()
  def from_internal(character) when is_atom(character) do
    Map.get(@character_to_external, character, 0xFF)
  end
end

defmodule Melee.Enums.Button do
  @moduledoc """
  A single button on a GCN controller.

  Atom names strip Python's `BUTTON_` prefix (`Button.BUTTON_A` -> `:a`).
  The control sticks (`:main`, `:c`) are considered "buttons" here.
  `to_command_string/1` returns the exact Dolphin input string that
  `controller.py` sends.

  ## Examples

      iex> Melee.Enums.Button.to_command_string(:a)
      "A"

      iex> Melee.Enums.Button.to_command_string(:main)
      "MAIN"

      iex> Melee.Enums.Button.from_command_string("D_LEFT")
      :d_left
  """

  @entries [
    a: "A",
    b: "B",
    x: "X",
    y: "Y",
    z: "Z",
    l: "L",
    r: "R",
    start: "START",
    d_up: "D_UP",
    d_down: "D_DOWN",
    d_left: "D_LEFT",
    d_right: "D_RIGHT",
    main: "MAIN",
    c: "C"
  ]
  @from_string Map.new(@entries, fn {name, s} -> {s, name} end)
  @to_string Map.new(@entries)

  @doc "Returns all `{atom, command_string}` entries."
  @spec entries() :: [{atom(), String.t()}]
  def entries, do: @entries

  @doc "Returns all button atoms."
  @spec buttons() :: [atom()]
  def buttons, do: Keyword.keys(@entries)

  @doc "Converts a button atom to the Dolphin input command string."
  @spec to_command_string(atom()) :: String.t()
  def to_command_string(button) when is_atom(button), do: Map.fetch!(@to_string, button)

  @doc """
  Converts a Dolphin input command string to a button atom.

  Unknown strings return `{:unknown, string}`.
  """
  @spec from_command_string(String.t()) :: atom() | {:unknown, String.t()}
  def from_command_string(s) when is_binary(s), do: Map.get(@from_string, s, {:unknown, s})
end
