defmodule Melee.StagesTest do
  use ExUnit.Case, async: true

  alias Melee.Stages

  doctest Melee.Stages

  # Raw integer stage IDs (the library convention)
  @battlefield 0x18
  @final_destination 0x19
  @dreamland 0x1A
  @fountain_of_dreams 0x8
  @pokemon_stadium 0x12
  @yoshis_story 0x6

  describe "edge positions (exact Python constants)" do
    test "edge_position by raw integer ID" do
      assert Stages.edge_position(@battlefield) == 71.3078536987
      assert Stages.edge_position(@final_destination) == 88.4735488892
      assert Stages.edge_position(@dreamland) == 80.1791534424
      assert Stages.edge_position(@fountain_of_dreams) == 66.2554016113
      assert Stages.edge_position(@pokemon_stadium) == 90.657852
      assert Stages.edge_position(@yoshis_story) == 58.907848
    end

    test "edge_ground_position by atom" do
      assert Stages.edge_ground_position(:battlefield) == 68.4000015259
      assert Stages.edge_ground_position(:final_destination) == 85.5656967163
      assert Stages.edge_ground_position(:dreamland) == 77.2713012695
      assert Stages.edge_ground_position(:fountain_of_dreams) == 63.3475494385
      assert Stages.edge_ground_position(:pokemon_stadium) == 87.75
      assert Stages.edge_ground_position(:yoshis_story) == 56
    end

    test "unknown stages return nil" do
      assert Stages.edge_position(0x42) == nil
      assert Stages.edge_ground_position(:no_stage) == nil
      assert Stages.blastzones(0) == nil
    end
  end

  describe "blastzones" do
    test "exact Python constants" do
      assert Stages.blastzones(@battlefield) == {-224, 224, 200, -108.8}
      assert Stages.blastzones(@final_destination) == {-246, 246, 188, -140}
      assert Stages.blastzones(@dreamland) == {-255, 255, 250, -123}
      assert Stages.blastzones(@fountain_of_dreams) == {-198.75, 198.75, 202.5, -146.25}
      assert Stages.blastzones(@pokemon_stadium) == {-230, 230, 180, -111}
      assert Stages.blastzones(@yoshis_story) == {-175.7, 173.6, 168, -91}
    end

    test "integer and atom keys agree" do
      assert Stages.blastzones(@yoshis_story) == Stages.blastzones(:yoshis_story)
    end
  end

  describe "platform positions" do
    test "top platform" do
      assert Stages.top_platform_position(@final_destination) == {nil, nil, nil}
      assert Stages.top_platform_position(@pokemon_stadium) == {nil, nil, nil}

      assert Stages.top_platform_position(@battlefield) ==
               {54.40010070800781, -18.80000114440918, 18.80000114440918}

      assert Stages.top_platform_position(@dreamland) ==
               {51.42539978027344, -19.01810073852539, 19.017099380493164}

      assert Stages.top_platform_position(@fountain_of_dreams) ==
               {42.750099182128906, -14.25, 14.25}

      assert Stages.top_platform_position(@yoshis_story) ==
               {42.000099182128906, -15.75, 15.75}
    end

    test "left platform" do
      assert Stages.left_platform_position(@final_destination) == {nil, nil, nil}
      assert Stages.left_platform_position(@pokemon_stadium) == {25.000099182128906, -55, -25}

      assert Stages.left_platform_position(@battlefield) ==
               {27.20009994506836, -57.60000228881836, -20}

      assert Stages.left_platform_position(@dreamland) ==
               {30.14219856262207, -61.39289855957031, -31.725400924682617}

      # Fountain of Dreams side platforms are unmapped upstream (TODO in Python)
      assert Stages.left_platform_position(@fountain_of_dreams) == {nil, nil, nil}
      assert Stages.left_platform_position(@yoshis_story) == {23.450098037719727, -59.5, -28.0}
    end

    test "right platform" do
      assert Stages.right_platform_position(@final_destination) == {nil, nil, nil}
      assert Stages.right_platform_position(@pokemon_stadium) == {25.000099182128906, 25, 55}

      assert Stages.right_platform_position(@battlefield) ==
               {27.20009994506836, 20, 57.60000228881836}

      assert Stages.right_platform_position(@dreamland) ==
               {30.242599487304688, 31.70359992980957, 63.074501037597656}

      assert Stages.right_platform_position(@fountain_of_dreams) == {nil, nil, nil}
      assert Stages.right_platform_position(@yoshis_story) == {23.450098037719727, 28.0, 59.5}
    end

    test "side_platform_position dispatches on the boolean" do
      assert Stages.side_platform_position(true, @battlefield) ==
               Stages.right_platform_position(@battlefield)

      assert Stages.side_platform_position(false, @battlefield) ==
               Stages.left_platform_position(@battlefield)
    end
  end

  describe "randall_position/1" do
    test "interval constant" do
      assert Stages.randall_interval() == 1200
    end

    test "bottom section (frame 0, frames_in = 125)" do
      {y, x_left, x_right} = Stages.randall_position(0)
      assert y == -33.2489
      assert_in_delta x_left, -101.850006103516 + 0.35484 * 125, 1.0e-9
      assert_in_delta x_right, -101.850006103516 + 11.9 + 0.35484 * 125, 1.0e-9
    end

    test "top section (frame 500, frames_in = 23)" do
      {y, x_left, x_right} = Stages.randall_position(500)
      assert y == -13.64989
      assert_in_delta x_right, 101.235443115234 - 0.35484 * 23, 1.0e-9
      assert_in_delta x_left, 101.235443115234 - 11.9 - 0.35484 * 23, 1.0e-9
    end

    test "right section start (frame 424)" do
      assert Stages.randall_position(424) == {-31.160232543945312, 91.35, 103.25}
    end

    test "left section start (frame 1023)" do
      assert Stages.randall_position(1023) == {-15.2778692245483, -103.6, -91.7}
    end

    test "hardcoded corner frames" do
      assert Stages.randall_position(416) ==
               {-33.184478759765625, 89.75263977050781, 89.75263977050781 + 11.9}

      assert Stages.randall_position(1075) ==
               {-33.07382583618164, -102.15814208984375, -102.15814208984375 + 11.9}
    end

    test "negative frames wrap around the interval like Python's modulo" do
      assert Stages.randall_position(-1) == Stages.randall_position(1199)
      assert Stages.randall_position(-1200) == Stages.randall_position(0)
    end

    test "total over a full cycle (no crashes, sane shape)" do
      for frame <- 0..1199 do
        assert {y, x_left, x_right} = Stages.randall_position(frame)
        assert is_number(y)
        assert x_left < x_right
      end
    end
  end
end
