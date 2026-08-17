defmodule Melee.MatchTest do
  use ExUnit.Case, async: true

  alias Melee.{Enums, GameState, Match, PlayerState}

  @css Enums.Menu.to_id(:character_select)
  @in_game Enums.Menu.to_id(:in_game)
  @fox Enums.Character.to_id(:fox)
  @falco Enums.Character.to_id(:falco)
  @cpu Enums.ControllerStatus.to_id(:controller_cpu)
  @human Enums.ControllerStatus.to_id(:controller_human)

  defp gs(menu, players) do
    %GameState{menu_state: menu, players: players}
  end

  defp player(attrs) do
    struct!(%PlayerState{}, attrs)
  end

  describe "port_configured?/2" do
    test "a human port is configured when the character matches" do
      gamestate = gs(@css, %{2 => player(character: @falco, controller_status: @human)})

      assert Match.port_configured?(gamestate, port: 2, character: @falco)
      refute Match.port_configured?(gamestate, port: 2, character: @fox)
    end

    test "a CPU port also needs level and CPU status" do
      spec = [port: 2, character: @falco, cpu_level: 9]

      ready = gs(@css, %{2 => player(character: @falco, cpu_level: 9, controller_status: @cpu)})
      assert Match.port_configured?(ready, spec)

      # Level still being dragged: the exact state the autostart gate
      # exists to hold out for.
      dragging =
        gs(@css, %{2 => player(character: @falco, cpu_level: 8, controller_status: @cpu)})

      refute Match.port_configured?(dragging, spec)

      # Right level but the panel never became a CPU.
      human = gs(@css, %{2 => player(character: @falco, cpu_level: 9, controller_status: @human)})
      refute Match.port_configured?(human, spec)
    end

    test "a missing port is not configured" do
      refute Match.port_configured?(gs(@css, %{}), port: 2, character: @falco)
    end
  end

  describe "at_character_select?/1" do
    test "recognizes both CSS variants and nothing else" do
      assert Match.at_character_select?(gs(@css, %{}))
      assert Match.at_character_select?(gs(Enums.Menu.to_id(:slippi_online_css), %{}))
      refute Match.at_character_select?(gs(@in_game, %{}))
      refute Match.at_character_select?(gs(Enums.Menu.to_id(:stage_select), %{}))
    end
  end

  describe "play/2 argument handling" do
    test "requires at least one port spec" do
      assert_raise ArgumentError, fn ->
        Match.play(self(), stage: :final_destination)
      end
    end

    test "a :team without teams: true raises" do
      assert_raise ArgumentError, ~r/:team but the match is not teams/, fn ->
        Match.play(self(),
          p1: [character: :fox, team: :blue],
          stage: :final_destination
        )
      end
    end

    test "an unknown team color raises" do
      assert_raise ArgumentError, ~r/team must be/, fn ->
        Match.play(self(),
          teams: true,
          p1: [character: :fox, team: :yellow],
          stage: :final_destination
        )
      end
    end
  end
end
