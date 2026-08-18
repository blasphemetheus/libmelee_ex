defmodule Melee.SlippiPadTest do
  use ExUnit.Case, async: true

  alias Melee.{Controller, ControllerState, SlippiPad}

  doctest Melee.SlippiPad

  # The pack must be byte-for-byte what Dolphin's pipe device produces
  # from the same inputs (Pipes.cpp FloatToU8 / SetAxis / SetButtonState),
  # so switching a port from pipes to the channel changes nothing.
  test "axis packing matches Pipes.cpp FloatToU8 at the extremes" do
    for {input, expected} <- [
          {1.0, 80},
          {0.0, 0x100 - 80},
          {0.5, 0}
        ] do
      wire = Controller.fix_analog_stick(input)
      state = %{ControllerState.neutral() | main_stick: {wire, wire}}
      <<_, _, x, y, _::binary>> = SlippiPad.pack(state)
      assert {x, y} == {expected, expected}, "input #{input}: got {#{x}, #{y}}"
    end
  end

  test "trigger packing applies the same quantization as the pipe write path" do
    state = %{ControllerState.neutral() | l_shoulder: 1.0, r_shoulder: 0.43}
    <<_::binary-size(6), l, r>> = SlippiPad.pack(state)

    assert l == trunc(Controller.fix_analog_trigger(1.0) * 255)
    assert r == trunc(Controller.fix_analog_trigger(0.43) * 255)
    assert l == 140
  end

  test "every button lands on its documented bit" do
    masks = [
      a: {0, 0x01},
      b: {0, 0x02},
      x: {0, 0x04},
      y: {0, 0x08},
      start: {0, 0x10},
      d_left: {1, 0x01},
      d_right: {1, 0x02},
      d_down: {1, 0x04},
      d_up: {1, 0x08},
      z: {1, 0x10},
      r: {1, 0x20},
      l: {1, 0x40}
    ]

    for {button, {index, mask}} <- masks do
      neutral = ControllerState.neutral()
      state = %{neutral | button: %{neutral.button | button => true}}
      <<b0, b1, _::binary>> = SlippiPad.pack(state)
      assert Enum.at([b0, b1], index) == mask, "#{button} misplaced"
    end
  end

  test "batch frames every port with the 0x01 command" do
    neutral = ControllerState.neutral()
    a_pressed = %{neutral | button: %{neutral.button | a: true}}

    assert SlippiPad.batch([{1, neutral}, {3, a_pressed}]) ==
             <<0x01, 2, 1, SlippiPad.pack(neutral)::binary, 3, SlippiPad.pack(a_pressed)::binary>>
  end
end
