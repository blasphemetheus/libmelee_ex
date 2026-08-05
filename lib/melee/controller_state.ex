defmodule Melee.ControllerState do
  @moduledoc """
  A snapshot of the state of a virtual GameCube controller.

  Mirrors libmelee's `ControllerState`. Buttons are keyed by the atoms
  `#{inspect([:a, :b, :x, :y, :z, :l, :r, :start, :d_up, :d_down, :d_left, :d_right])}`.
  Stick axes range 0.0..1.0 with 0.5 neutral; shoulders range 0.0..1.0.
  """

  @buttons [:a, :b, :x, :y, :z, :l, :r, :start, :d_up, :d_down, :d_left, :d_right]

  @type button ::
          :a | :b | :x | :y | :z | :l | :r | :start | :d_up | :d_down | :d_left | :d_right

  @type stick :: {float(), float()}

  @type t :: %__MODULE__{
          button: %{button() => boolean()},
          processed_button: %{button() => boolean()},
          main_stick: stick(),
          c_stick: stick(),
          raw_main_stick: {integer(), integer()},
          l_shoulder: float(),
          r_shoulder: float()
        }

  defstruct button: Map.from_keys(@buttons, false),
            processed_button: Map.from_keys(@buttons, false),
            main_stick: {0.5, 0.5},
            c_stick: {0.5, 0.5},
            raw_main_stick: {0, 0},
            l_shoulder: 0.0,
            r_shoulder: 0.0

  @doc "The list of physical boolean buttons, in libmelee order."
  @spec buttons() :: [button()]
  def buttons, do: @buttons

  @doc """
  A neutral controller state: no buttons pressed, sticks centered,
  shoulders released.

  ## Examples

      iex> Melee.ControllerState.neutral().main_stick
      {0.5, 0.5}

      iex> Melee.ControllerState.neutral().button.a
      false
  """
  @spec neutral() :: t()
  def neutral, do: %__MODULE__{}
end
