defmodule Melee.TechTest do
  use ExUnit.Case, async: true

  alias Melee.{PlayerState, Tech}

  doctest Melee.Tech

  defp player(overrides) do
    struct!(%PlayerState{action: 0x0E, on_ground: true, action_frame: 1}, overrides)
  end

  describe "wavedash" do
    test "jumps, then airdodges diagonally on the FIRST airborne frame" do
      tech = Tech.new(:wavedash, :fox, direction: :left)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))

      # Still grounded through jumpsquat: keep the jump released so it
      # stays a fresh edge, no airdodge yet.
      {:cont, tech, [{:release, :y}]} =
        Tech.step(tech, player(%{action: 0x18, action_frame: 2}))

      # First airborne frame: L + down-diagonal toward :left.
      {:cont, tech, commands} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19}))

      assert {:tilt, :main, x, y} = List.keyfind(commands, :tilt, 0)
      assert x < 0.2 and y < 0.3
      assert {:press, :l} in commands

      # Done at the special (wavedash) landing.
      {:done, _tech, [:release_all]} =
        Tech.step(tech, player(%{action: 0x2B}))
    end

    test "waits for the ground before starting" do
      tech = Tech.new(:wavedash, :marth)
      {:cont, _tech, []} = Tech.step(tech, player(%{on_ground: false, action: 0x1D}))
    end
  end

  describe "shffl" do
    test "hop, aerial, fast fall, pulsed L through the fall" do
      tech = Tech.new(:shffl, :fox, aerial: :nair)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))
      {:cont, tech, [{:release, :y}]} = Tech.step(tech, player(%{action: 0x18}))

      # Airborne rising: nair via A.
      {:cont, tech, commands} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19, speed_y_self: 2.0}))

      assert {:press, :a} in commands

      # Falling in the aerial: fast fall.
      {:cont, tech, commands} =
        Tech.step(tech, player(%{on_ground: false, action: 0x41, speed_y_self: -0.5}))

      assert {:tilt, :main, 0.5, 0.0} in commands

      # The L pulse has a press edge at least every 6 frames, so one
      # always lands inside the 7-frame L-cancel window.
      {presses, _tech} =
        Enum.map_reduce(1..12, tech, fn _i, tech ->
          {:cont, tech, commands} =
            Tech.step(tech, player(%{on_ground: false, action: 0x41, speed_y_self: -3.0}))

          {commands, tech}
        end)

      assert Enum.count(presses, &({:press, :l} in &1)) == 2

      # Done at the aerial landing.
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x46, on_ground: true}))
    end

    test "directional aerials go on the c-stick" do
      tech = Tech.new(:shffl, :falco, aerial: :dair)
      {:cont, tech, _} = Tech.step(tech, player(%{}))
      {:cont, _tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      assert {:tilt, :c, 0.5, 0.0} in commands
    end
  end

  describe "dash_dance" do
    test "alternates full tilts on the interval and never finishes" do
      tech = Tech.new(:dash_dance, :marth, interval: 4)

      {tilts, _tech} =
        Enum.map_reduce(1..16, tech, fn _i, tech ->
          {:cont, tech, [{:tilt, :main, x, 0.5}]} = Tech.step(tech, player(%{action: 0x14}))
          {x, tech}
        end)

      assert Enum.slice(tilts, 0, 4) |> Enum.uniq() |> length() == 1
      assert Enum.at(tilts, 0) != Enum.at(tilts, 5)
      assert Enum.uniq(tilts) |> Enum.sort() == [0.0, 1.0]
    end
  end

  describe "jumpsquat table" do
    test "covers every playable character" do
      for char <- [
            :mario,
            :fox,
            :cptfalcon,
            :dk,
            :kirby,
            :bowser,
            :link,
            :sheik,
            :ness,
            :peach,
            :popo,
            :pikachu,
            :samus,
            :yoshi,
            :jigglypuff,
            :mewtwo,
            :luigi,
            :marth,
            :zelda,
            :ylink,
            :doc,
            :falco,
            :pichu,
            :gameandwatch,
            :ganondorf,
            :roy
          ] do
        tech = Tech.new(:short_hop, char)
        assert tech.jumpsquat in 3..8, "#{char}"
      end
    end

    test "fox is 3, falco is 5, bowser is 8" do
      assert Tech.new(:short_hop, :fox).jumpsquat == 3
      assert Tech.new(:short_hop, :falco).jumpsquat == 5
      assert Tech.new(:short_hop, :bowser).jumpsquat == 8
    end
  end

  describe "tier 2" do
    test "waveland airdodges the first airborne frame and finishes on the special landing" do
      tech = Tech.new(:waveland, :fox, direction: :right)
      # Grounded: waits.
      {:cont, tech, []} = Tech.step(tech, player(%{}))
      # Airborne: L + diagonal immediately.
      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x1D}))
      assert {:press, :l} in commands
      assert {:tilt, :main, x, y} = List.keyfind(commands, :tilt, 0)
      assert x > 0.8 and y < 0.3
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x2B}))
    end

    test "pivot dashes, flicks opposite for one frame, then settles to standing" do
      tech = Tech.new(:pivot, :marth, direction: :right, dash_frames: 3)
      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, player(%{action: 0x14}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14}))
      # The flick: exactly one opposite-direction frame.
      {:cont, tech, [{:tilt, :main, 0.0, 0.5}]} = Tech.step(tech, player(%{action: 0x14}))
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]} = Tech.step(tech, player(%{action: 0x12}))
      {:done, _tech, []} = Tech.step(tech, player(%{action: 0x0E}))
    end

    test "ground tech presses L exactly once, near the ground, never early" do
      tech = Tech.new(:tech, :fox, direction: :left, height: 8.0)

      # Tumbling but high up: hold fire (an early press = 40f lockout).
      {:cont, tech, []} =
        Tech.step(
          tech,
          player(%{on_ground: false, action: 0x26, speed_y_self: -2.0})
          |> Map.put(:position, %Melee.Position{x: 0.0, y: 30.0})
        )

      # Close to the ground: one press, roll direction held.
      {:cont, tech, commands} =
        Tech.step(
          tech,
          player(%{on_ground: false, action: 0x26, speed_y_self: -2.0})
          |> Map.put(:position, %Melee.Position{x: 0.0, y: 5.0})
        )

      assert {:press, :l} in commands
      assert {:tilt, :main, 0.0, 0.5} in commands

      # Tech state entered -> done.
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0xC9, on_ground: true}))
    end

    test "ledgedash releases, double-jumps in, and wavelands" do
      tech = Tech.new(:ledgedash, :fox, direction: :left)

      # Not hanging yet: waits.
      {:cont, tech, []} = Tech.step(tech, player(%{on_ground: false, action: 0x1D}))

      # Hanging: release AWAY from the stage (stage is :left -> tilt right).
      {:cont, tech, [{:tilt, :main, 0.95, 0.5}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0xFD}))

      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x1D}))

      # Jump back in toward the stage.
      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x1D}))
      assert {:press, :y} in commands
      assert {:tilt, :main, 0.05, 0.5} in commands

      # Aerial jump seen and risen above the lip -> airdodge toward the stage.
      {:cont, tech, commands} =
        Tech.step(
          tech,
          player(%{on_ground: false, action: 0x1B})
          |> Map.put(:position, %Melee.Position{x: 90.0, y: 2.0})
        )

      assert {:press, :l} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x2B}))
    end
  end

  describe "tier 3" do
    test "waveshine: shine, jump-cancel on frame 3, airdodge out" do
      tech = Tech.new(:waveshine, :fox, direction: :right)

      {:cont, tech, commands} = Tech.step(tech, player(%{}))
      assert {:press, :b} in commands

      shine = Melee.Enums.Action.to_id(:down_b_ground_start)

      # Shine frame 2: not yet cancellable.
      {:cont, tech, [{:release, :b}]} =
        Tech.step(tech, player(%{action: shine, action_frame: 2}))

      # Frame 3: jump cancel.
      {:cont, tech, commands} =
        Tech.step(tech, player(%{action: shine, action_frame: 3}))

      assert {:press, :y} in commands

      # Airborne: airdodge.
      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      assert {:press, :l} in commands
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x2B}))
    end

    test "short hop laser fires airborne and fast falls" do
      tech = Tech.new(:short_hop_laser, :falco)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))
      {:cont, tech, [{:release, :y}]} = Tech.step(tech, player(%{action: 0x18}))

      {:cont, tech, commands} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19, speed_y_self: 2.0}))

      assert {:press, :b} in commands

      {:cont, tech, commands} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19, speed_y_self: -1.0}))

      assert {:tilt, :main, 0.5, 0.0} in commands
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{on_ground: true, action: 0x2A}))
    end

    test "djc aerial double-jumps and immediately attacks" do
      tech = Tech.new(:djc_aerial, :ness, aerial: :dair)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))

      {:cont, tech, [{:release, :y}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19}))

      {:cont, tech, [{:press, :x}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19}))

      {:cont, tech, commands} =
        Tech.step(tech, player(%{on_ground: false, action: 0x1B}))

      assert {:tilt, :c, 0.5, 0.0} in commands
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{on_ground: true, action: 0x4A}))
    end
  end

  describe "tier 4 hit-response" do
    test "di holds the stick through hitlag plus one resolution frame" do
      tech = Tech.new(:di, :fox, stick: :up)

      {:cont, tech, []} = Tech.step(tech, player(%{hitlag_left: 0}))
      {:cont, tech, [{:tilt, :main, 0.5, 1.0}]} = Tech.step(tech, player(%{hitlag_left: 5}))
      {:cont, tech, [{:tilt, :main, 0.5, 1.0}]} = Tech.step(tech, player(%{hitlag_left: 2}))
      # Hitlag over: hold ONE more frame (the resolution frame), then done.
      {:done, _tech, [{:tilt, :main, 0.5, 1.0}]} = Tech.step(tech, player(%{hitlag_left: 0}))
    end

    test "sdi alternates zones every hitlag frame and stops with hitlag" do
      tech = Tech.new(:sdi, :fox, direction: :up)

      {:cont, tech, [{:tilt, :main, 0.5, 1.0}]} = Tech.step(tech, player(%{hitlag_left: 6}))
      {:cont, tech, [{:tilt, :main, 0.85, 0.9}]} = Tech.step(tech, player(%{hitlag_left: 5}))
      {:cont, tech, [{:tilt, :main, 0.5, 1.0}]} = Tech.step(tech, player(%{hitlag_left: 4}))
      {:done, _tech, [{:tilt, :main, 0.5, 0.5}]} = Tech.step(tech, player(%{hitlag_left: 0}))
    end

    test "asdi_down parks the c-stick down for the whole hitlag" do
      tech = Tech.new(:asdi_down, :fox)
      {:cont, tech, [{:tilt, :c, 0.5, 0.0}]} = Tech.step(tech, player(%{hitlag_left: 4}))
      {:cont, tech, [{:tilt, :c, 0.5, 0.0}]} = Tech.step(tech, player(%{hitlag_left: 1}))
      {:done, _tech, [{:tilt, :c, 0.5, 0.5}]} = Tech.step(tech, player(%{hitlag_left: 0}))
    end
  end

  describe "mewtwo kit" do
    test "shadow ball charges for N frames then shield-cancels to store" do
      tech = Tech.new(:shadow_ball_charge, :mewtwo, frames: 3)

      {:cont, tech, [{:press, :b}]} = Tech.step(tech, player(%{}))
      {:cont, tech, [{:release, :b}]} = Tech.step(tech, player(%{action: 0x156}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x156}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x156}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x156}))
      # Budget reached: shield-cancel.
      {:cont, tech, [{:press, :l}]} = Tech.step(tech, player(%{action: 0x156}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 179}))
    end

    test "a full charge (its own hold loop) cancels immediately" do
      tech = Tech.new(:shadow_ball_charge, :mewtwo, frames: 300)
      {:cont, tech, _} = Tech.step(tech, player(%{}))
      {:cont, tech, _} = Tech.step(tech, player(%{action: 0x156}))
      {:cont, tech, [{:press, :l}]} = Tech.step(tech, player(%{action: 0x157}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x158}))
    end

    test "firing a stored ball resumes the charge, then B-edges out" do
      tech = Tech.new(:shadow_ball_fire, :mewtwo)

      {:cont, tech, [{:press, :b}]} = Tech.step(tech, player(%{}))
      # The press resumed the charge, not fired it.
      {:cont, tech, [{:release, :b}]} = Tech.step(tech, player(%{action: 0x156}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x156}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x156}))
      # Second edge fires.
      {:cont, tech, [{:press, :b}]} = Tech.step(tech, player(%{action: 0x156}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x159}))
    end

    test "teledgehog turns away, drifts out below the lip, teleports up into the hang" do
      tech = Tech.new(:teledgehog, :mewtwo, direction: :right, edge_x: 60.0)

      # Facing the ledge: turn away first (the fall only grabs a ledge
      # it faces).
      {:cont, tech, [{:tilt, :main, 0.2, 0.5}]} = Tech.step(tech, player(%{facing: true}))

      {:cont, tech, commands} = Tech.step(tech, player(%{facing: false}))
      assert {:press, :y} in commands

      {:cont, tech, [{:release, :y}]} = Tech.step(tech, player(%{action: 0x18, facing: false}))

      # Airborne: backward-drift out toward the ledge.
      {:cont, tech, [{:release, :y}]} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))

      {:cont, tech, [{:tilt, :main, 0.9, 0.5}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x1D}))

      # Past the lip but not deep enough: hold back stage-ward, keep
      # sinking hugging the lip.
      {:cont, tech, [{:tilt, :main, 0.1, 0.5}]} =
        Tech.step(
          tech,
          player(%{on_ground: false, action: 0x1D})
          |> Map.put(:position, %Melee.Position{x: 63.0, y: -5.0})
        )

      # Below dive depth: up-B aimed mostly up, a touch stage-ward.
      {:cont, tech, commands} =
        Tech.step(
          tech,
          player(%{on_ground: false, action: 0x1D})
          |> Map.put(:position, %Melee.Position{x: 64.0, y: -16.0})
        )

      assert {:press, :b} in commands
      assert {:tilt, :main, 0.35, 1.0} in commands

      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x170}))
      assert {:tilt, :main, 0.35, 1.0} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{on_ground: false, action: 0xFD}))
    end
  end
end
