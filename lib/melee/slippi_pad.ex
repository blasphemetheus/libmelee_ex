defmodule Melee.SlippiPad do
  @moduledoc """
  Packs a `Melee.ControllerState` into the 8-byte Slippi pad buffer the
  direct channel's input batches carry (`SLIPPI_PAD_DATA_SIZE`), byte
  for byte what Dolphin's pipe device would have produced from the same
  inputs — so switching a port from pipes to the channel changes
  nothing about what the game sees.

  Layout (from Ishiiruka's `Pipes.cpp` / `SlippiPad.h`):

  | byte | contents |
  | --- | --- |
  | 0 | buttons: A 0x01, B 0x02, X 0x04, Y 0x08, START 0x10 |
  | 1 | D_LEFT 0x01, D_RIGHT 0x02, D_DOWN 0x04, D_UP 0x08, Z 0x10, R 0x20, L 0x40 |
  | 2-5 | main X/Y, C X/Y: `floor((v - 0.5) * 254)` as a signed byte |
  | 6-7 | L/R analog: `trunc(v * 255)` |

  Sticks come pre-quantized out of `Melee.Controller` (its state stores
  the wire value); trigger analogs are stored raw there, so the same
  `fix_analog_trigger/1` the pipe write path applies is applied here.
  """

  import Bitwise

  alias Melee.{Controller, ControllerState}

  @batch_cmd 0x01

  @doc """
  Pack one controller state into the 8 data bytes.

  ## Examples

      iex> Melee.SlippiPad.pack(Melee.ControllerState.neutral())
      <<0, 0, 0, 0, 0, 0, 0, 0>>

      iex> state = %{Melee.ControllerState.neutral() | button: %{Melee.ControllerState.neutral().button | a: true, z: true}}
      iex> Melee.SlippiPad.pack(state)
      <<0x01, 0x10, 0, 0, 0, 0, 0, 0>>

      iex> state = %{Melee.ControllerState.neutral() | main_stick: {Melee.Controller.fix_analog_stick(1.0), 0.5}}
      iex> <<x, _::binary>> = binary_part(Melee.SlippiPad.pack(state), 2, 6)
      iex> x
      80
  """
  @spec pack(ControllerState.t()) :: <<_::64>>
  def pack(%ControllerState{} = state) do
    b = state.button
    {mx, my} = state.main_stick
    {cx, cy} = state.c_stick

    byte0 =
      bit(b.a, 0x01) + bit(b.b, 0x02) + bit(b.x, 0x04) + bit(b.y, 0x08) + bit(b.start, 0x10)

    byte1 =
      bit(b.d_left, 0x01) + bit(b.d_right, 0x02) + bit(b.d_down, 0x04) + bit(b.d_up, 0x08) +
        bit(b.z, 0x10) + bit(b.r, 0x20) + bit(b.l, 0x40)

    <<byte0, byte1, axis(mx), axis(my), axis(cx), axis(cy), trigger(state.l_shoulder),
      trigger(state.r_shoulder)>>
  end

  @doc """
  Pack a pad batch message: `{port, state}` pairs into the direct
  channel's input frame (`0x01`, count, then port + pad per entry).

  ## Examples

      iex> Melee.SlippiPad.batch([{1, Melee.ControllerState.neutral()}])
      <<0x01, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0>>
  """
  @spec batch([{1..4, ControllerState.t()}]) :: binary()
  def batch(pads) do
    entries = for {port, state} <- pads, into: <<>>, do: <<port, pack(state)::binary>>
    <<@batch_cmd, length(pads), entries::binary>>
  end

  @doc "One atomic mixed batch: 0x03, count, then port/mode and 8 raw or 44 processed/RNG bytes."
  def mixed_batch(pads) do
    ports = Enum.map(pads, &elem(&1, 0))

    unless length(ports) in 1..4 and Enum.uniq(ports) == ports and
             Enum.all?(ports, &(&1 in 1..4)),
           do: raise(ArgumentError, "expected unique controller ports in 1..4")

    entries =
      for {port, state} <- pads, into: <<>> do
        case state.processed_input do
          nil -> <<port, 0, pack(state)::binary>>
          input -> <<port, 1, pack_processed(input)::binary>>
        end
      end

    <<3, length(pads), entries::binary>>
  end

  @doc "Encode original game-unit floats and physical inputs as a 44-byte big-endian record."
  def pack_processed(p) do
    for key <- [:main_x, :main_y, :c_x, :c_y] do
      v = Map.fetch!(p, key)

      unless is_number(v) and v >= -1 and v <= 1,
        do: raise(ArgumentError, "#{key} must be in -1..1")
    end

    for key <- [:trigger, :l_trigger, :r_trigger] do
      v = Map.fetch!(p, key)

      unless is_number(v) and v >= 0 and v <= 1,
        do: raise(ArgumentError, "#{key} must be in 0..1")
    end

    for {key, max} <- [buttons: 0xFFFFFFFF, physical_buttons: 0xFFFF, rng_seed: 0xFFFFFFFF] do
      v = Map.fetch!(p, key)

      unless is_integer(v) and v >= 0 and v <= max,
        do: raise(ArgumentError, "invalid #{key}")
    end

    for key <- [:raw_main_x, :raw_main_y, :raw_c_x, :raw_c_y] do
      v = Map.fetch!(p, key)

      unless is_integer(v) and v in -128..127,
        do:
          raise(
            ArgumentError,
            "#{key} is missing or not a signed byte; this replay cannot use exact injection"
          )
    end

    <<p.main_x::float-big-32, p.main_y::float-big-32, p.c_x::float-big-32, p.c_y::float-big-32,
      p.trigger::float-big-32, p.buttons::unsigned-big-32, p.physical_buttons::unsigned-big-16,
      0::16, p.l_trigger::float-big-32, p.r_trigger::float-big-32, p.raw_main_x::signed-8,
      p.raw_main_y::signed-8, p.raw_c_x::signed-8, p.raw_c_y::signed-8,
      p.rng_seed::unsigned-big-32>>
  end

  defp bit(true, mask), do: mask
  defp bit(_, _mask), do: 0

  # Pipes.cpp FloatToU8: s8 floor((v - 0.5) * 254), reinterpreted.
  defp axis(v), do: floor((v - 0.5) * 254) &&& 0xFF

  # Pipes.cpp SetAxis L/R: u8(v * 255), after the same trigger
  # quantization the pipe write path applies.
  defp trigger(v) do
    trunc(Controller.fix_analog_trigger(v) * 255)
  end
end
