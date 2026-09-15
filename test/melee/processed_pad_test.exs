defmodule Melee.ProcessedPadTest do
  use ExUnit.Case, async: true
  alias Melee.{Controller, ControllerState, SlippiPad}

  defp input do
    %{
      rng_seed: 0xDEADBEEF,
      main_x: -0.9921875,
      main_y: -0.0,
      c_x: 0.25,
      c_y: -0.5,
      trigger: 0.375,
      buttons: 0x80000100,
      physical_buttons: 0x0020,
      l_trigger: 0.125,
      r_trigger: 0.25,
      raw_main_x: -128,
      raw_main_y: 127,
      raw_c_x: 3,
      raw_c_y: -4
    }
  end

  test "processed floats, logical buttons and physical fields have distinct big-endian slots" do
    p = SlippiPad.pack_processed(input())
    assert byte_size(p) == 44

    assert <<0xBF7E0000::32, 0x80000000::32, 0x3E800000::32, 0xBF000000::32, 0x3EC00000::32,
             0x80000100::32, 0x0020::16, 0::16, 0x3E000000::32, 0x3E800000::32, 128, 127, 3, 252,
             0xDEADBEEF::32>> == p
  end

  test "mixed batch commits both ports and keeps legacy bytes identical" do
    byte = ControllerState.neutral()
    processed = %{byte | processed_input: input()}

    assert <<3, 2, 1, 0, 0::64, 2, 1, _::binary-size(44)>> =
             SlippiPad.mixed_batch([{1, byte}, {2, processed}])

    assert SlippiPad.batch([{1, byte}]) == <<1, 1, 1, 0::64>>
  end

  test "rejects absent raw fields, out-of-range values and duplicate ports" do
    for {key, value} <- [
          raw_c_x: nil,
          raw_main_x: 128,
          main_x: 1.1,
          trigger: -0.1,
          buttons: 0x100000000
        ] do
      assert_raise ArgumentError, fn -> SlippiPad.pack_processed(Map.put(input(), key, value)) end
    end

    assert_raise ArgumentError, fn ->
      SlippiPad.mixed_batch([{1, ControllerState.neutral()}, {1, ControllerState.neutral()}])
    end
  end

  test "an exact override expires after one commit and release_all clears it" do
    c = start_supervised!({Controller, pipe_path: "/tmp/not-opened-processed-pad-test"})
    assert :ok = Controller.set_processed(c, input())
    assert Controller.take_direct(c).processed_input == input()
    assert Controller.take_direct(c).processed_input == nil
    Controller.set_processed(c, input())
    Controller.release_all(c)
    assert Controller.current(c).processed_input == nil
  end
end
