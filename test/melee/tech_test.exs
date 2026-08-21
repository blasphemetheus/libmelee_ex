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

  describe "tier 5 universal batch" do
    test "jc_grab presses Z during jumpsquat and finishes on the catch" do
      tech = Tech.new(:jc_grab, :fox)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{action: 0x14}))
      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x18}))
      assert {:press, :z} in commands
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0xD4}))
    end

    test "moonwalk dashes, rolls through down, parks in down-back" do
      tech = Tech.new(:moonwalk, :fox, direction: :right, dash_frames: 2, slide_frames: 2)

      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, player(%{}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14}))
      # Roll frame: down-forward along the rim.
      {:cont, tech, [{:tilt, :main, 0.65, 0.08}]} = Tech.step(tech, player(%{action: 0x14}))
      # Then the down-back park (no smash-turn, no crouch).
      {:cont, tech, [{:tilt, :main, 0.12, 0.25}]} = Tech.step(tech, player(%{action: 0x14}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x14}))
    end

    test "fox_trot regaps off the dash's own frame counter" do
      tech = Tech.new(:fox_trot, :fox, direction: :right, reps: 2, dash_frames: 2)

      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, player(%{}))

      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} =
        Tech.step(tech, player(%{action: 0x14, action_frame: 1}))

      # The dash reached its regap frame: neutral gap.
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]} =
        Tech.step(tech, player(%{action: 0x14, action_frame: 2}))

      # Neutral holds until the dash animation actually ENDS.
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14, action_frame: 3}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14, action_frame: 4}))

      # Dash over (standing): re-smash.
      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} =
        Tech.step(tech, player(%{action: 0x0E, action_frame: 1}))

      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} =
        Tech.step(tech, player(%{action: 0x14, action_frame: 1}))

      {:done, _tech, [:release_all]} =
        Tech.step(tech, player(%{action: 0x14, action_frame: 2}))
    end

    test "crouch_cancel holds down + c-down through hitlag then resolves" do
      tech = Tech.new(:crouch_cancel, :fox)

      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x28}))
      assert {:tilt, :main, 0.5, 0.0} in commands
      assert {:tilt, :c, 0.5, 0.0} in commands

      {:cont, tech, _} = Tech.step(tech, player(%{action: 0x28, hitlag_left: 4}))
      {:cont, tech, _} = Tech.step(tech, player(%{action: 0x28, hitlag_left: 1}))
      {:done, _tech, commands} = Tech.step(tech, player(%{action: 0x28, hitlag_left: 0}))
      assert {:tilt, :main, 0.5, 0.0} in commands
    end

    test "wavedash_oos shields, jump-cancels, airdodges" do
      tech = Tech.new(:wavedash_oos, :fox, direction: :left)

      {:cont, tech, [{:press, :r}]} = Tech.step(tech, player(%{}))
      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{action: 179}))
      {:cont, tech, [{:release, :y}]} = Tech.step(tech, player(%{action: 0x18}))

      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      assert {:press, :l} in commands
      assert {:tilt, :main, 0.05, 0.2} in commands
      assert {:release, :r} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x2B}))
    end

    test "powershield presses R and finishes on GuardReflect" do
      tech = Tech.new(:powershield, :fox)
      {:cont, tech, [{:press, :r}]} = Tech.step(tech, player(%{}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 178}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0xB6}))
    end

    test "shield_drop tilts into the notch band and finishes airborne" do
      tech = Tech.new(:shield_drop, :fox)

      {:cont, tech, [{:press, :r}]} = Tech.step(tech, player(%{}))
      {:cont, tech, [{:tilt, :main, 0.5, 0.16}]} = Tech.step(tech, player(%{action: 179}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 179}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{on_ground: false, action: 0xF4}))
    end
  end

  describe "tier 5 spacie extensions" do
    test "drillshine runs a dair shffl then pulses the shine out of the landing" do
      tech = Tech.new(:drillshine, :fox)

      # Sub-machine: the shffl hop.
      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))
      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      assert {:tilt, :c, 0.5, 0.0} in commands

      # Landing ends the shffl: shine press same step.
      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x4A, on_ground: true}))
      assert {:press, :b} in commands
      assert {:tilt, :main, 0.5, 0.0} in commands

      {:done, _tech, [:release_all]} =
        Tech.step(tech, player(%{action: Melee.Enums.Action.to_id(:down_b_ground_start)}))
    end

    test "double_laser pulses B edges through the hop and ends on landing" do
      tech = Tech.new(:double_laser, :falco)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))
      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      assert {:press, :b} in commands
      {:cont, tech, [{:release, :b}]} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      {:cont, tech, [{:press, :b}]} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x2A}))
    end

    test "shine_turnaround taps back mid-shine and finishes when facing flips" do
      tech = Tech.new(:shine_turnaround, :fox)
      shine = Melee.Enums.Action.to_id(:down_b_ground_start)

      {:cont, tech, commands} = Tech.step(tech, player(%{facing: true}))
      assert {:press, :b} in commands

      {:cont, tech, _} = Tech.step(tech, player(%{action: shine, action_frame: 2, facing: true}))

      {:cont, tech, commands} =
        Tech.step(tech, player(%{action: shine, action_frame: 5, facing: true}))

      assert {:tilt, :main, 0.0, 0.5} in commands

      {:done, _tech, [:release_all]} =
        Tech.step(tech, player(%{action: shine, action_frame: 7, facing: false}))
    end
  end

  describe "tier 5 character kits" do
    test "float_cancel full-hops, arms the float at the apex, aerials, releases" do
      tech = Tech.new(:float_cancel, :peach, aerial: :nair, float_frames: 1)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))
      # Jump held through jumpsquat (full hop).
      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{action: 0x18}))

      # Rising fast: wait for the apex.
      {:cont, tech, []} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19, speed_y_self: 3.0}))

      {:cont, tech, []} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19, speed_y_self: 2.0}))

      # Apex: down-tap with jump held arms the float.
      {:cont, tech, [{:tilt, :main, 0.5, 0.25}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19, speed_y_self: 0.5}))

      # Float state: neutral the stick, then aerial.
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x155}))

      # One float beat, then the aerial IN the float.
      {:cont, tech, []} = Tech.step(tech, player(%{on_ground: false, action: 0x155}))
      {:cont, tech, [{:press, :a}]} = Tech.step(tech, player(%{on_ground: false, action: 0x155}))

      # Float-aerial started (its own family): release the float and
      # fast fall so the touchdown lands DURING the attack — that IS
      # the float cancel (4-frame landing, live-measured).
      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x158}))
      assert {:release, :y} in commands
      assert {:tilt, :main, 0.5, 0.0} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{on_ground: true, action: 0x2A}))
    end

    test "gentleman links three slow jabs and stops" do
      tech = Tech.new(:gentleman, :cptfalcon)

      {:cont, tech, [{:press, :a}]} = Tech.step(tech, player(%{}))
      {:cont, tech, [{:release, :a}]} = Tech.step(tech, player(%{action: 0x2C, action_frame: 1}))
      {:cont, tech, [{:press, :a}]} = Tech.step(tech, player(%{action: 0x2C, action_frame: 4}))
      {:cont, tech, [{:release, :a}]} = Tech.step(tech, player(%{action: 0x2D, action_frame: 1}))
      {:cont, tech, [{:press, :a}]} = Tech.step(tech, player(%{action: 0x2D, action_frame: 4}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x2E, action_frame: 1}))
    end

    test "pivot_smash flicks then c-sticks the new facing" do
      tech = Tech.new(:pivot_smash, :marth, direction: :right, dash_frames: 2)

      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, player(%{}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14}))
      {:cont, tech, [{:tilt, :main, 0.0, 0.5}]} = Tech.step(tech, player(%{action: 0x14}))

      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x14}))
      assert {:tilt, :c, 0.0, 0.5} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x3C}))
    end

    test "missile_cancel hops, side-Bs, finishes on landing" do
      tech = Tech.new(:missile_cancel, :samus, direction: :right)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))

      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      assert {:press, :b} in commands
      assert {:tilt, :main, 1.0, 0.5} in commands

      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      assert {:release, :b} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{on_ground: true, action: 0x2A}))
    end

    test "ics_desync grabs, then Bs only after the catch connects" do
      tech = Tech.new(:ics_desync, :popo)

      {:cont, tech, [{:press, :z}]} = Tech.step(tech, player(%{}))
      {:cont, tech, [{:release, :z}]} = Tech.step(tech, player(%{action: 0xD4}))

      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0xD5}))
      assert {:press, :b} in commands

      {:cont, tech, []} = Tech.step(tech, player(%{action: 0xD8}))
      {:cont, _tech, [{:release, :b}]} = Tech.step(tech, player(%{action: 0xD8}))
    end
  end

  describe "tier 5 batch 3" do
    test "shine_grab shines, jump-cancels, and Zs the jumpsquat" do
      tech = Tech.new(:shine_grab, :fox)
      shine = Melee.Enums.Action.to_id(:down_b_ground_start)

      {:cont, tech, commands} = Tech.step(tech, player(%{}))
      assert {:press, :b} in commands

      {:cont, tech, commands} =
        Tech.step(tech, player(%{action: shine, action_frame: 4}))

      assert {:press, :y} in commands

      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x18}))
      assert {:press, :z} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0xD4}))
    end

    test "instant_rar runs, turns, jumps, and bairs while drifting forward" do
      tech = Tech.new(:instant_rar, :cptfalcon, direction: :right, run_frames: 2)

      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, player(%{}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14}))
      # Flick backward into the turn.
      {:cont, tech, [{:tilt, :main, 0.0, 0.5}]} = Tech.step(tech, player(%{action: 0x14}))

      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x12}))
      assert {:press, :y} in commands

      {:cont, tech, [{:release, :y}]} = Tech.step(tech, player(%{action: 0x18}))

      {:cont, tech, commands} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      assert {:tilt, :main, 0.85, 0.5} in commands
      assert {:tilt, :c, 0.85, 0.5} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{on_ground: true, action: 0x48}))
    end
  end

  describe "combos" do
    test "uthrow_uair grabs, throws on the CatchWait edge, rides the jump, uairs" do
      tech = Tech.new(:uthrow_uair, :fox, uair_delay: 1)

      {:cont, tech, [{:press, :z}]} = Tech.step(tech, player(%{}))
      # CatchPull is NOT enough — the up-tilt needs a fresh edge in
      # CatchWait or the throw never comes out.
      {:cont, tech, [{:release, :z}]} = Tech.step(tech, player(%{action: 0xD5}))

      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0xD8}))
      assert {:tilt, :main, 0.5, 1.0} in commands

      # ThrowUp: neutral so the held up doesn't tap-jump.
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]} = Tech.step(tech, player(%{action: 0xDD}))

      # Endlag over: full hop.
      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{action: 0x0E}))
      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{action: 0x18}))

      # Airborne: ride up before the swing.
      {:cont, tech, [{:release, :y}]} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))
      {:cont, tech, []} = Tech.step(tech, player(%{on_ground: false, action: 0x19}))

      {:cont, tech, [{:tilt, :c, 0.5, 1.0}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19}))

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{on_ground: true, action: 0x49}))
    end
  end

  describe "super wavedash" do
    test "bombs, then flicks away-toward on the configured frame pair" do
      tech = Tech.new(:super_wavedash, :samus, direction: :right, flick_frame: 2, slide_frames: 1)

      {:cont, tech, commands} = Tech.step(tech, player(%{}))
      assert {:press, :b} in commands
      assert {:tilt, :main, 0.5, 0.0} in commands

      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x155}))
      assert {:release, :b} in commands

      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x155}))
      assert {:tilt, :main, 0.5, 0.5} in commands

      # Flick frame: AWAY first...
      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x155}))
      assert {:tilt, :main, 0.0, 0.5} in commands

      # ...TOWARD the very next frame...
      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, player(%{action: 0x155}))

      # ...then neutral (holding past the pair shrinks the slide).
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]} = Tech.step(tech, player(%{action: 0x0E}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x0E}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x0E}))
    end
  end

  describe "no impact land" do
    test "hops, double-jumps at trigger_y, done on touchdown" do
      tech = Tech.new(:no_impact_land, :marth, trigger_y: 6.0, hop: :full)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))
      # Full hop: hold through jumpsquat.
      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{action: 0x18}))

      {:cont, tech, [{:release, :y}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19, position: %{x: 0.0, y: 1.0}}))

      # Below the trigger: wait.
      {:cont, tech, []} =
        Tech.step(tech, player(%{on_ground: false, action: 0x1D, position: %{x: 0.0, y: 4.0}}))

      # At the trigger: the DJ press.
      {:cont, tech, [{:press, :x}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x1D, position: %{x: 0.0, y: 6.2}}))

      {:cont, tech, [{:release, :x}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x1B, position: %{x: 0.0, y: 12.0}}))

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x0E}))
    end

    test "gives up cleanly if it lands without the trigger firing" do
      tech = Tech.new(:no_impact_land, :marth, trigger_y: 99.0)
      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))
      {:cont, tech, [{:release, :y}]} = Tech.step(tech, player(%{on_ground: false, action: 0x1D}))
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x2A}))
    end
  end

  describe "v-cancel" do
    test "full hop, L at press_frame, done on hitlag" do
      tech = Tech.new(:v_cancel, :fox, press_frame: 2)

      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{}))
      {:cont, tech, [{:press, :y}]} = Tech.step(tech, player(%{action: 0x18}))

      {:cont, tech, commands} =
        Tech.step(tech, player(%{on_ground: false, action: 0x19}))

      assert {:release, :y} in commands

      airborne = player(%{on_ground: false, action: 0x1D})
      {:cont, tech, []} = Tech.step(tech, airborne)
      {:cont, tech, []} = Tech.step(tech, airborne)
      # Frame press_frame: the L press (the input that v-cancels).
      {:cont, tech, [{:press, :l}]} = Tech.step(tech, airborne)

      # Hit inside the window: done in hitlag.
      {:done, _tech, [:release_all]} =
        Tech.step(tech, player(%{on_ground: false, action: 0x54, hitlag_left: 5}))
    end
  end

  describe "pkt2" do
    test "casts up-B, walks the steer plan, rides the launch out" do
      tech = Tech.new(:pkt2, :ness, steer: [{1.0, 0.5, 2}, {0.5, 0.0, 2}])

      {:cont, tech, commands} = Tech.step(tech, player(%{}))
      assert {:press, :b} in commands
      assert {:tilt, :main, 0.5, 1.0} in commands

      # Casting: wait for the hold animation (0x167).
      casting = player(%{action: 0x166})
      {:cont, tech, [{:release, :b}, {:tilt, :main, 0.5, +0.0}]} = Tech.step(tech, casting)
      {:cont, tech, [{:release, :b}, {:tilt, :main, 0.5, +0.0}]} = Tech.step(tech, casting)

      # Bolt out: the steer plan runs segment by segment.
      holding = player(%{action: 0x167})
      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, holding)
      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, holding)
      {:cont, tech, [{:tilt, :main, 0.5, +0.0}]} = Tech.step(tech, holding)

      # The bolt lands on his own head: hitlag marks the contact.
      {:cont, _tech, [{:tilt, :main, 0.5, 0.5}]} =
        Tech.step(tech, player(%{action: 0x167, hitlag_left: 4}))
    end
  end

  describe "walljump" do
    test "hops out, hugs in, detects wall contact, flicks away, done on upward velocity" do
      tech = Tech.new(:walljump, :fox, direction: :right, pin_frames: 1, out_frames: 1)

      # Grounded: hop out with a little outward drift.
      {:cont, tech, commands} = Tech.step(tech, player(%{}))
      assert {:press, :y} in commands
      assert {:tilt, :main, 0.62, 0.5} in commands

      {:cont, tech, [{:release, :y}]} = Tech.step(tech, player(%{action: 0x18}))

      # Airborne but not yet past the lip: keep drifting out.
      {:cont, tech, commands} =
        Tech.step(
          tech,
          player(%{on_ground: false, action: 0x19, position: %{x: 84.0, y: 4.0}})
        )

      assert {:tilt, :main, 0.62, 0.5} in commands

      # One out_frame of drift...
      {:cont, tech, []} =
        Tech.step(
          tech,
          player(%{on_ground: false, action: 0x1D, position: %{x: 86.0, y: 6.0}})
        )

      # ...then hold hard INTO the wall.
      {:cont, tech, [{:tilt, :main, 0.05, 0.5}]} =
        Tech.step(
          tech,
          player(%{on_ground: false, action: 0x1D, position: %{x: 88.6, y: 3.0}})
        )

      # Sinking with the x still moving: no contact yet.
      tech =
        Enum.reduce([88.5, 88.2, 87.9, 87.6, 87.3, 87.0], tech, fn x, tech ->
          {:cont, tech, []} =
            Tech.step(
              tech,
              player(%{
                on_ground: false,
                action: 0x1D,
                speed_y_self: -2.0,
                position: %{x: x, y: -6.0}
              })
            )

          tech
        end)

      # x stopped while falling: CONTACT. Pin, then the away flick.
      pinned =
        player(%{
          on_ground: false,
          action: 0x1D,
          speed_y_self: -2.0,
          position: %{x: 87.0, y: -9.0}
        })

      {:cont, tech, []} = Tech.step(tech, pinned)
      {:cont, tech, []} = Tech.step(tech, pinned)
      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, pinned)

      # Upward velocity with no jump spent: the walljump came out.
      {:done, _tech, [:release_all]} =
        Tech.step(
          tech,
          player(%{on_ground: false, action: 0x1D, speed_y_self: 2.6})
        )
    end
  end

  describe "walltech" do
    test "one L press near the wall from tumble, done on the wall tech state" do
      tech = Tech.new(:walltech, :fox, wall_x: 85.57, margin: 8.0)

      # Tumbling but far from the wall: hold fire.
      {:cont, tech, []} =
        Tech.step(
          tech,
          player(%{
            on_ground: false,
            action: 0x26,
            speed_y_attack: -1.5,
            position: %{x: 40.0, y: 5.0}
          })
        )

      # Rising past the wall: still not armed (the press waits for
      # the way DOWN).
      {:cont, tech, []} =
        Tech.step(
          tech,
          player(%{
            on_ground: false,
            action: 0x26,
            speed_y_attack: 2.0,
            position: %{x: 80.0, y: 20.0}
          })
        )

      # Falling onto the wall: the single press, held into the wall.
      {:cont, tech, commands} =
        Tech.step(
          tech,
          player(%{
            on_ground: false,
            action: 0x26,
            speed_y_attack: -1.5,
            position: %{x: 80.0, y: -5.0}
          })
        )

      assert {:press, :l} in commands
      # Into the wall = toward the stage (the character is OUTSIDE).
      assert {:tilt, :main, +0.0, 0.5} in commands

      {:done, _tech, [:release_all]} =
        Tech.step(tech, player(%{on_ground: false, action: 0xCA}))
    end
  end

  describe "pool round" do
    test "illusion presses side-B and shortens with a second B" do
      tech = Tech.new(:illusion, :fox, direction: :right, shorten_frame: 2)

      {:cont, tech, commands} = Tech.step(tech, player(%{}))
      assert {:press, :b} in commands
      assert {:tilt, :main, 1.0, 0.5} in commands

      dashing = player(%{action: 0x15F})
      # Recognizes the dash; frame counter starts.
      {:cont, tech, [{:release, :b}]} = Tech.step(tech, dashing)
      {:cont, tech, [{:release, :b}]} = Tech.step(tech, dashing)
      # shorten_frame: the second B press.
      {:cont, tech, [{:press, :b}]} = Tech.step(tech, dashing)
      {:cont, tech, [{:release, :b}]} = Tech.step(tech, player(%{action: 0x160}))
      {:cont, tech, [{:release, :b}]} = Tech.step(tech, player(%{action: 0x160}))
      # Move over, grounded again.
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x0E}))
    end

    test "haxdash releases, jumps after dj_delay, done on the regrab" do
      tech = Tech.new(:haxdash, :fox, dj_delay: 1)

      hanging = player(%{on_ground: false, action: 0xFD})
      {:cont, tech, [{:tilt, :main, 0.5, 0.35}]} = Tech.step(tech, hanging)

      falling = player(%{on_ground: false, action: 0x1D})
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]} = Tech.step(tech, falling)
      {:cont, tech, []} = Tech.step(tech, falling)
      {:cont, tech, [{:press, :x}]} = Tech.step(tech, falling)

      {:done, _tech, [:release_all]} =
        Tech.step(tech, player(%{on_ground: false, action: 0xFC}))
    end

    test "ledgestall releases, double jumps, then up-Bs to the regrab" do
      tech = Tech.new(:ledgestall, :marth, delay: 1, up_b_delay: 1)

      {:cont, tech, [{:tilt, :main, 0.95, 0.5}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0xFD}))

      falling = player(%{on_ground: false, action: 0x1D})
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]} = Tech.step(tech, falling)
      # Falls for the delay, then the double jump.
      {:cont, tech, []} = Tech.step(tech, falling)
      {:cont, tech, [{:press, :x}]} = Tech.step(tech, falling)

      rising = player(%{on_ground: false, action: 0x1C})
      {:cont, tech, [{:release, :x}]} = Tech.step(tech, rising)

      {:cont, tech, commands} = Tech.step(tech, rising)
      assert {:press, :b} in commands
      assert {:tilt, :main, 0.5, 1.0} in commands

      {:done, _tech, [:release_all]} =
        Tech.step(tech, player(%{on_ground: false, action: 0xFC}))
    end

    test "ledgehop laser releases, jumps in, and pulses B until landing" do
      tech = Tech.new(:ledgehop_laser, :falco, direction: :right, fire_delay: 3)

      {:cont, tech, [{:tilt, :main, 0.5, 0.35}]} =
        Tech.step(tech, player(%{on_ground: false, action: 0xFD}))

      falling = player(%{on_ground: false, action: 0x1D})
      {:cont, tech, [{:tilt, :main, 0.5, 0.5}]} = Tech.step(tech, falling)
      {:cont, tech, commands} = Tech.step(tech, falling)
      assert {:press, :x} in commands
      assert {:tilt, :main, 0.25, 0.5} in commands

      {:cont, tech, [{:release, :x}]} = Tech.step(tech, falling)
      {:cont, tech, [{:release, :x}]} = Tech.step(tech, falling)
      # fire_delay reached (transition frame), then the B pulses.
      {:cont, tech, [{:release, :x}]} = Tech.step(tech, falling)
      {:cont, tech, [{:press, :b}]} = Tech.step(tech, falling)
      {:cont, tech, [{:release, :b}]} = Tech.step(tech, falling)

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x2A}))
    end

    test "pivot grab flicks opposite and presses Z on the turn" do
      tech = Tech.new(:pivot_grab, :marth, direction: :right, dash_frames: 2)

      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, player(%{action: 0x14}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14}))
      {:cont, tech, [{:tilt, :main, 0.0, 0.5}]} = Tech.step(tech, player(%{action: 0x14}))

      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x12}))
      assert {:press, :z} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0xD4}))
    end

    test "boost grab cancels the dash attack with Z" do
      tech = Tech.new(:boost_grab, :fox, direction: :right, dash_frames: 2)

      {:cont, tech, [{:tilt, :main, 1.0, 0.5}]} = Tech.step(tech, player(%{}))
      {:cont, tech, []} = Tech.step(tech, player(%{action: 0x14}))
      {:cont, tech, [{:press, :a}]} = Tech.step(tech, player(%{action: 0x14}))

      # Dash attack out: the Z cancel.
      {:cont, tech, commands} = Tech.step(tech, player(%{action: 0x32}))
      assert {:press, :z} in commands

      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0xD6}))
    end
  end

  describe "wobble" do
    test "grabs, then down+A on the interval until reps run out" do
      tech = Tech.new(:wobble, :popo, interval: 4, reps: 2)

      {:cont, tech, [{:press, :z}]} = Tech.step(tech, player(%{}))

      # Grab connected, Nana ready: park the stick down.
      holding = player(%{action: 0xD8})
      {:cont, tech, [{:tilt, :main, 0.5, +0.0}]} = Tech.step(tech, holding)

      # Rep 1: the down+A press, released two frames later.
      {:cont, tech, commands} = Tech.step(tech, holding)
      assert {:press, :a} in commands
      {:cont, tech, []} = Tech.step(tech, holding)
      {:cont, tech, [{:release, :a}]} = Tech.step(tech, holding)
      {:cont, tech, []} = Tech.step(tech, holding)
      # Interval elapsed: recycle into rep 2.
      {:cont, tech, []} = Tech.step(tech, holding)
      {:cont, tech, commands} = Tech.step(tech, holding)
      assert {:press, :a} in commands

      # The victim escaping ends the routine.
      {:done, _tech, [:release_all]} = Tech.step(tech, player(%{action: 0x0E}))
    end
  end
end
