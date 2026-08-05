defmodule Melee.FrameDataTest do
  use ExUnit.Case, async: true

  doctest Melee.FrameData

  alias Melee.ECB
  alias Melee.FrameData
  alias Melee.PlayerState
  alias Melee.Position

  # Golden values in this file were generated from the Python reference
  # implementation in /home/blewf/git/exphil/.venv (libmelee):
  #
  #     from melee.framedata import FrameData
  #     from melee.enums import Action, Character, Stage
  #     fd = FrameData()
  #
  # The exact call producing each expected value is cited above each assert.

  describe "zero_indexed?/2 and character_data/1 (pre-existing API)" do
    test "still work with integer ids" do
      assert FrameData.zero_indexed?(22, 323)
      refute FrameData.zero_indexed?(22, 322)
      assert FrameData.character_data(0x01)["Gravity"] == 0.23
    end

    test "also accept atoms now" do
      assert FrameData.character_data(:fox)["InitDJSpeed"] == 4.186
    end
  end

  describe "hitbox frame queries" do
    test "first/last hitbox frame, count, iasa, frame_count for Marth fsmash" do
      # fd.first_hitbox_frame(Character.MARTH, Action.FSMASH_MID) == 10
      assert FrameData.first_hitbox_frame(:marth, :fsmash_mid) == 10
      # fd.last_hitbox_frame(Character.MARTH, Action.FSMASH_MID) == 13
      assert FrameData.last_hitbox_frame(:marth, :fsmash_mid) == 13
      # fd.hitbox_count(Character.MARTH, Action.FSMASH_MID) == 1
      assert FrameData.hitbox_count(:marth, :fsmash_mid) == 1
      # fd.iasa(Character.MARTH, Action.FSMASH_MID) == 48
      assert FrameData.iasa(:marth, :fsmash_mid) == 48
      # fd.frame_count(Character.MARTH, Action.FSMASH_MID) == 49
      assert FrameData.frame_count(:marth, :fsmash_mid) == 49
    end

    test "Fox aerials" do
      # fd.first_hitbox_frame(Character.FOX, Action.NAIR) == 4
      assert FrameData.first_hitbox_frame(:fox, :nair) == 4
      # fd.last_hitbox_frame(Character.FOX, Action.NAIR) == 31
      assert FrameData.last_hitbox_frame(:fox, :nair) == 31
      # fd.hitbox_count(Character.FOX, Action.DAIR) == 7
      assert FrameData.hitbox_count(:fox, :dair) == 7
      # fd.iasa(Character.FOX, Action.UAIR) == 36
      assert FrameData.iasa(:fox, :uair) == 36
      # fd.frame_count(Character.FOX, Action.BAIR) == 39
      assert FrameData.frame_count(:fox, :bair) == 39
    end

    test "Fox shine hitbox is on frame 1 of DOWN_B_GROUND_START" do
      # fd.first_hitbox_frame(Character.FOX, Action.DOWN_B_GROUND_START) == 1
      # fd.last_hitbox_frame(Character.FOX, Action.DOWN_B_GROUND_START) == 1
      assert FrameData.first_hitbox_frame(:fox, :down_b_ground_start) == 1
      assert FrameData.last_hitbox_frame(:fox, :down_b_ground_start) == 1
    end

    test "special-cased hitbox counts" do
      # fd.hitbox_count(Character.SAMUS, Action.SWORD_DANCE_3_MID) == 7
      assert FrameData.hitbox_count(:samus, :sword_dance_3_mid) == 7
      # fd.hitbox_count(Character.YLINK, Action.SWORD_DANCE_4_MID) == 10
      assert FrameData.hitbox_count(:ylink, :sword_dance_4_mid) == 10
    end

    test "-1/0 sentinels for non-attacks" do
      # fd.first_hitbox_frame(Character.FOX, Action.WALK_SLOW) == -1
      assert FrameData.first_hitbox_frame(:fox, :walk_slow) == -1
      assert FrameData.last_hitbox_frame(:fox, :walk_slow) == -1
      assert FrameData.hitbox_count(:fox, :walk_slow) == 0
      assert FrameData.iasa(:fox, :walk_slow) == -1
      assert FrameData.frame_count(:fox, :walk_slow) == -1
    end
  end

  describe "classification" do
    test "attack?/grab?/roll?/shield?/max_jumps" do
      # fd.is_attack(Character.FOX, Action.NAIR) == True
      assert FrameData.attack?(:fox, :nair)
      refute FrameData.attack?(:fox, :walk_slow)
      # fd.is_grab(Character.FOX, Action.GRAB) == True
      assert FrameData.grab?(:fox, :grab)
      # fd.is_grab(Character.BOWSER, Action.NEUTRAL_B_ATTACKING_AIR) == True
      assert FrameData.grab?(:bowser, :neutral_b_attacking_air)
      # fd.is_roll(Character.MARTH, Action.MARTH_COUNTER) == True
      assert FrameData.roll?(:marth, :marth_counter)
      # fd.is_shield(Action.SHIELD) == True; fd.is_shield(Action.NAIR) == False
      assert FrameData.shield?(:shield)
      refute FrameData.shield?(:nair)
      # fd.max_jumps(Character.JIGGLYPUFF) == 5; fd.max_jumps(Character.FOX) == 1
      assert FrameData.max_jumps(:jigglypuff) == 5
      assert FrameData.max_jumps(:fox) == 1
    end

    test "attack_state" do
      # fd.attack_state(Character.MARTH, Action.FSMASH_MID, 1) == AttackState.WINDUP
      assert FrameData.attack_state(:marth, :fsmash_mid, 1) == :windup
      # ... 12 -> ATTACKING, 50 -> COOLDOWN
      assert FrameData.attack_state(:marth, :fsmash_mid, 12) == :attacking
      assert FrameData.attack_state(:marth, :fsmash_mid, 50) == :cooldown
      # fd.attack_state(Character.FOX, Action.WALK_SLOW, 3) == AttackState.NOT_ATTACKING
      assert FrameData.attack_state(:fox, :walk_slow, 3) == :not_attacking
    end
  end

  describe "range queries" do
    test "range_forward/range_backward" do
      # fd.range_forward(Character.MARTH, Action.FSMASH_MID, 0) == 32.011064291000004
      assert FrameData.range_forward(:marth, :fsmash_mid, 0) == 32.011064291000004
      # fd.range_forward(Character.MARTH, Action.FSMASH_MID, 11) == 28.5527665615
      assert FrameData.range_forward(:marth, :fsmash_mid, 11) == 28.5527665615
      # fd.range_forward(Character.FOX, Action.FSMASH_MID, 0) == 17.0667324067
      assert FrameData.range_forward(:fox, :fsmash_mid, 0) == 17.0667324067
      # fd.range_backward(Character.MARTH, Action.FSMASH_MID, 0) == 0
      assert FrameData.range_backward(:marth, :fsmash_mid, 0) == 0
      # fd.range_backward(Character.FOX, Action.DOWNSMASH, 0) == 13.334775447799998
      assert FrameData.range_backward(:fox, :downsmash, 0) == 13.334775447799998
    end

    test "in_range" do
      # attacker: Marth FSMASH_MID at frame 1, x=0, y=0, facing right, grounded,
      # all self-speeds 0. Defender: Fox at (20, 0). Stage FINAL_DESTINATION.
      # fd.in_range(attacker, defender, Stage.FINAL_DESTINATION) == 10
      #
      # Note: Python's in_range reads `defender.y`, an attribute that no longer
      # exists on this libmelee version's PlayerState (AttributeError on real
      # states). The golden value was generated passing y = position.y, which
      # is the evident intent and what this port implements.
      attacker = %PlayerState{
        character: Melee.Enums.Character.to_id(:marth),
        action: Melee.Enums.Action.to_id(:fsmash_mid),
        action_frame: 1,
        position: %Position{x: 0.0, y: 0.0},
        facing: true,
        on_ground: true,
        speed_ground_x_self: 0.0,
        speed_air_x_self: 0.0,
        speed_y_self: 0.0
      }

      defender = %PlayerState{
        character: Melee.Enums.Character.to_id(:fox),
        position: %Position{x: 20.0, y: 0.0}
      }

      assert FrameData.in_range(attacker, defender, :final_destination) == 10

      # Same, defender at (50, 0):
      # fd.in_range(attacker, defender, Stage.FINAL_DESTINATION) == 0
      far = %{defender | position: %Position{x: 50.0, y: 0.0}}
      assert FrameData.in_range(attacker, far, :final_destination) == 0
    end
  end

  describe "jump physics" do
    test "dj_height / frames_until_dj_apex" do
      # Fox, jumps_left=1, speed_y_self=0:
      # fd.dj_height(s) == 40.204 ; fd.frames_until_dj_apex(s) == 19
      fox = %PlayerState{
        character: Melee.Enums.Character.to_id(:fox),
        jumps_left: 1,
        speed_y_self: 0.0,
        action: Melee.Enums.Action.to_id(:falling),
        action_frame: 1
      }

      assert FrameData.dj_height(fox) == 40.204
      assert FrameData.frames_until_dj_apex(fox) == 19

      # Jigglypuff, jumps_left=3:
      # fd.dj_height(s) == 16.147999999999993 ; fd.frames_until_dj_apex(s) == 22
      jiggs = %{fox | character: Melee.Enums.Character.to_id(:jigglypuff), jumps_left: 3}
      assert FrameData.dj_height(jiggs) == 16.147999999999993
      assert FrameData.frames_until_dj_apex(jiggs) == 22

      # Peach, jumps_left=1, not in JUMPING_ARIAL_FORWARD:
      # fd.dj_height(s) == 33.218964577 ; fd.frames_until_dj_apex(s) == 1
      peach = %{fox | character: Melee.Enums.Character.to_id(:peach)}
      assert FrameData.dj_height(peach) == 33.218964577
      assert FrameData.frames_until_dj_apex(peach) == 1

      # Fox with jump used (jumps_left=0), speed_y_self=1.0:
      # fd.dj_height(s) == 1.7000000000000002
      used = %{fox | jumps_left: 0, speed_y_self: 1.0}
      assert FrameData.dj_height(used) == 1.7000000000000002
    end
  end

  describe "rolls and slides" do
    test "last_roll_frame" do
      # fd.last_roll_frame(Character.FOX, Action.ROLL_FORWARD) == 31
      assert FrameData.last_roll_frame(:fox, :roll_forward) == 31
      # fd.last_roll_frame(Character.FOX, Action.NAIR) == -1
      assert FrameData.last_roll_frame(:fox, :nair) == -1
    end

    test "roll_end_position" do
      # Fox ROLL_FORWARD, frame 1, at (0, 0), Battlefield:
      # facing True  -> 33.6000003814
      # facing False -> -33.6000003814
      fox = %PlayerState{
        character: Melee.Enums.Character.to_id(:fox),
        action: Melee.Enums.Action.to_id(:roll_forward),
        action_frame: 1,
        position: %Position{x: 0.0, y: 0.0},
        facing: true
      }

      assert FrameData.roll_end_position(fox, :battlefield) == 33.6000003814

      assert FrameData.roll_end_position(%{fox | facing: false}, :battlefield) ==
               -33.6000003814

      # Fox ROLL_BACKWARD, facing True -> -33.599996566799994
      back = %{fox | action: Melee.Enums.Action.to_id(:roll_backward)}
      assert FrameData.roll_end_position(back, :battlefield) == -33.599996566799994

      # Fox EDGE_ROLL_SLOW at (60, 0), facing False -> 24.324478149599997
      edge = %{
        fox
        | action: Melee.Enums.Action.to_id(:edge_roll_slow),
          position: %Position{x: 60.0, y: 0.0},
          facing: false
      }

      assert FrameData.roll_end_position(edge, :battlefield) == 24.324478149599997

      # Missing frame data (Python KeyError path) returns current x:
      # Fox NAIR at frame 99, x=12.5 -> 12.5
      missing = %{
        fox
        | action: Melee.Enums.Action.to_id(:nair),
          action_frame: 99,
          position: %Position{x: 12.5, y: 0.0}
      }

      assert FrameData.roll_end_position(missing, :battlefield) == 12.5
    end

    test "slide_distance" do
      # Fox STANDING frame 1:
      # fd.slide_distance(s, 2.0, 40) == 18.71999999999999
      # fd.slide_distance(s, -1.5, 10) == -10.599999999999996
      fox = %PlayerState{
        character: Melee.Enums.Character.to_id(:fox),
        action: Melee.Enums.Action.to_id(:standing),
        action_frame: 1
      }

      assert FrameData.slide_distance(fox, 2.0, 40) == 18.71999999999999
      assert FrameData.slide_distance(fox, -1.5, 10) == -10.599999999999996

      # Fox TECH_MISS_UP frame 1:
      # fd.slide_distance(s, 2.0, 40) == 33.65900000000003
      tech = %{fox | action: Melee.Enums.Action.to_id(:tech_miss_up)}
      assert FrameData.slide_distance(tech, 2.0, 40) == 33.65900000000003
    end
  end

  describe "project_hit_location" do
    test "flies until end of hitstun on FD" do
      # Fox at (10, 25), speed_x_attack=3.0, speed_y_attack=2.0, speed_y_self=0,
      # hitstun_frames_left=30, ecb.bottom.y=0, Stage.FINAL_DESTINATION:
      # fd.project_hit_location(s, Stage.FINAL_DESTINATION)
      #   == (81.54096422011499, 7.153976146743321, 30)
      fox = %PlayerState{
        character: Melee.Enums.Character.to_id(:fox),
        position: %Position{x: 10.0, y: 25.0},
        speed_x_attack: 3.0,
        speed_y_attack: 2.0,
        speed_y_self: 0.0,
        hitstun_frames_left: 30,
        ecb: %ECB{bottom: %Position{x: 0.0, y: 0.0}}
      }

      assert FrameData.project_hit_location(fox, :final_destination) ==
               {81.54096422011499, 7.153976146743321, 30}
    end

    test "explicit frame limit on Battlefield" do
      # Same state but at (-40, 60) with speed_x_attack=-1.0, frames=20:
      # fd.project_hit_location(s, Stage.BATTLEFIELD, 20)
      #   == (-55.666500259605414, 53.79300051921085, 30)
      # (third element is hitstun_frames_left — a quirk kept from Python)
      fox = %PlayerState{
        character: Melee.Enums.Character.to_id(:fox),
        position: %Position{x: -40.0, y: 60.0},
        speed_x_attack: -1.0,
        speed_y_attack: 2.0,
        speed_y_self: 0.0,
        hitstun_frames_left: 30,
        ecb: %ECB{bottom: %Position{x: 0.0, y: 0.0}}
      }

      assert FrameData.project_hit_location(fox, :battlefield, 20) ==
               {-55.666500259605414, 53.79300051921085, 30}
    end
  end

  describe "bmove?" do
    # Note: this libmelee version's is_bmove crashes in Python (references the
    # removed Action.UNKNOWN_ANIMATION), so these expectations come from the
    # source logic: false for Peach's float/smash exceptions, true for any
    # action id >= Action.LASER_GUN_PULL (0x155).
    test "b-move classification" do
      assert FrameData.bmove?(:fox, :down_b_ground)
      assert FrameData.bmove?(:fox, :laser_gun_pull)
      refute FrameData.bmove?(:peach, :laser_gun_pull)
      refute FrameData.bmove?(:peach, :neutral_b_charging)
      refute FrameData.bmove?(:peach, :sword_dance_1)
      assert FrameData.bmove?(:peach, :sword_dance_3_high)
      refute FrameData.bmove?(:fox, :walk_slow)
      refute FrameData.bmove?(:fox, 0xFFFF)
    end
  end

  describe "get_frame/3" do
    test "returns the raw frame map" do
      # fd.framedata[Character.FOX][Action.DOWN_B_GROUND_START][1]
      frame = FrameData.get_frame(:fox, :down_b_ground_start, 1)
      assert frame.hitbox_1_status
      assert frame.hitbox_1_size == 7.9994878769
      assert frame.hitbox_1_x == -0.6033039093
      assert frame.hitbox_1_y == 6.797442572
      refute frame.projectile
      assert FrameData.get_frame(:fox, :walk_slow, 1) == nil
    end
  end
end
