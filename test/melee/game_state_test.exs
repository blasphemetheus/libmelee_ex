defmodule Melee.GameStateTest do
  use ExUnit.Case, async: true

  alias Melee.{GameState, PlayerState}

  doctest Melee.GameState

  defp teams_gs do
    %GameState{
      is_teams: true,
      players: %{
        1 => %PlayerState{team_id: 0},
        2 => %PlayerState{team_id: 0},
        3 => %PlayerState{team_id: 1},
        4 => %PlayerState{team_id: 2}
      }
    }
  end

  describe "allies/2 and enemies/2" do
    test "three-team games partition correctly" do
      gs = teams_gs()

      assert GameState.allies(gs, 3) == []
      assert GameState.enemies(gs, 3) |> Enum.map(&elem(&1, 0)) == [1, 2, 4]
      assert GameState.allies(gs, 2) |> Enum.map(&elem(&1, 0)) == [1]
    end

    test "a port not in the game has no allies and everyone as enemies" do
      gs = teams_gs()
      assert GameState.allies(gs, 5) == []
      # An unknown port has no team, so in teams everyone reads enemy.
      assert GameState.enemies(gs, 5) |> length() == 4
    end

    test "free-for-all: no allies, everyone else an enemy" do
      gs = %{teams_gs() | is_teams: false}
      assert GameState.allies(gs, 1) == []
      assert GameState.enemies(gs, 1) |> Enum.map(&elem(&1, 0)) == [2, 3, 4]
    end

    test "nil player entries are skipped" do
      gs = %GameState{
        is_teams: true,
        players: %{1 => %PlayerState{team_id: 0}, 2 => nil, 3 => %PlayerState{team_id: 0}}
      }

      assert GameState.allies(gs, 1) |> Enum.map(&elem(&1, 0)) == [3]
      assert GameState.enemies(gs, 1) == []
    end
  end
end
