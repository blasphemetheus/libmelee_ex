defmodule MeleeTest do
  use ExUnit.Case, async: true

  alias Melee.{ControllerState, GameState, PlayerState}

  doctest Melee.ControllerState

  describe "GameState" do
    test "defaults mirror libmelee" do
      gs = %GameState{}
      assert gs.frame == -10_000
      # FINAL_DESTINATION
      assert gs.stage == 0x19
      # IN_GAME
      assert gs.menu_state == 2
      assert gs.players == %{}
    end

    test "in_game?/1 covers in-game and sudden death only" do
      assert GameState.in_game?(%GameState{menu_state: 2})
      assert GameState.in_game?(%GameState{menu_state: 3})
      refute GameState.in_game?(%GameState{menu_state: 8})
    end

    test "port_detector/3 finds a unique character/costume match" do
      players = %{
        1 => %PlayerState{character: 0x02, costume: 1},
        2 => %PlayerState{character: 0x09, costume: 0}
      }

      gs = %GameState{players: players}
      assert GameState.port_detector(gs, 0x02, 1) == 1
      assert GameState.port_detector(gs, 0x02, 3) == 0

      dup = %GameState{players: Map.put(players, 2, %PlayerState{character: 0x02, costume: 1})}
      assert GameState.port_detector(dup, 0x02, 1) == 0
    end
  end

  describe "PlayerState" do
    test "defaults mirror libmelee" do
      p = %PlayerState{}
      assert p.character == 0xFF
      assert p.shield_strength == 60.0
      assert p.facing == true
      assert p.action == -1
      assert p.controller_state == ControllerState.neutral()
    end
  end
end
