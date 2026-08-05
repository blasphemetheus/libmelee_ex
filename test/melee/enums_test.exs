defmodule Melee.EnumsTest do
  use ExUnit.Case, async: true

  alias Melee.Enums.{
    Action,
    AttackState,
    Button,
    Character,
    ControllerStatus,
    ControllerType,
    Menu,
    ProjectileType,
    Stage,
    SubMenu
  }

  doctest Melee.Enums.Stage
  doctest Melee.Enums.Menu
  doctest Melee.Enums.SubMenu
  doctest Melee.Enums.ControllerStatus
  doctest Melee.Enums.ControllerType
  doctest Melee.Enums.AttackState
  doctest Melee.Enums.Character
  doctest Melee.Enums.Button
  doctest Melee.Enums.Action
  doctest Melee.Enums.ProjectileType

  @int_enums [
    Stage,
    Menu,
    SubMenu,
    ControllerStatus,
    AttackState,
    Character,
    Action,
    ProjectileType
  ]

  describe "roundtrip from_id/to_id" do
    for mod <- @int_enums do
      test "#{inspect(mod)} roundtrips over all canonical entries" do
        mod = unquote(mod)

        for {atom, id} <- mod.entries() do
          assert mod.from_id(id) == atom
          assert mod.to_id(atom) == id
          assert mod.to_id(mod.from_id(id)) == id
          assert mod.from_id(mod.to_id(atom)) == atom
        end
      end
    end
  end

  describe "unknown-value fallback" do
    for mod <- @int_enums do
      test "#{inspect(mod)} returns {:unknown, id} and roundtrips it" do
        mod = unquote(mod)
        known = MapSet.new(mod.entries(), fn {_a, id} -> id end)
        unknown = Enum.find(100_000..200_000, fn n -> not MapSet.member?(known, n) end)

        assert mod.from_id(unknown) == {:unknown, unknown}
        assert mod.to_id({:unknown, unknown}) == unknown
        assert mod.name(unknown) == "UNKNOWN(#{unknown})"
      end
    end
  end

  describe "spot-checks against Python wire values" do
    test "Character internal IDs" do
      assert Character.from_id(0x00) == :mario
      assert Character.from_id(0x01) == :fox
      assert Character.from_id(0x02) == :cptfalcon
      assert Character.from_id(0x0F) == :jigglypuff
      assert Character.from_id(0x10) == :mewtwo
      assert Character.to_id(:marth) == 0x12
      assert Character.to_id(:falco) == 0x16
      assert Character.to_id(:ganondorf) == 0x19
      assert Character.to_id(:sandbag) == 0x20
      assert Character.to_id(:unknown_character) == 0xFF
    end

    test "Character external (CSS) conversion" do
      assert Character.to_internal(0x0A) == :fox
      assert Character.to_internal(0x00) == :doc
      assert Character.to_internal(0x17) == :marth
      assert Character.to_internal(0x99) == :unknown_character
      assert Character.from_internal(:fox) == 0x0A
      assert Character.from_internal(:roy) == 0x18
      # Not on the CSS -> 0xFF, matching Python
      assert Character.from_internal(:sandbag) == 0xFF
      # from_css: CSS ID straight to raw internal integer
      assert Character.from_css(0x0A) == 0x01
      assert Character.from_css(0x00) == 0x15
      assert Character.from_css(0x99) == nil
      assert Character.from_css(nil) == nil
    end

    test "valid?/1" do
      assert Stage.valid?(0x19)
      refute Stage.valid?(0x42)
      assert SubMenu.valid?(33)
      refute SubMenu.valid?(34)
      assert Action.valid?(0x18D)
      refute Action.valid?(0x9999)
      refute Stage.valid?(:battlefield)
    end

    test "Stage IDs and external conversion" do
      assert Stage.from_id(0) == :no_stage
      assert Stage.from_id(0x19) == :final_destination
      assert Stage.from_id(0x18) == :battlefield
      assert Stage.from_id(0x12) == :pokemon_stadium
      assert Stage.from_id(0x1A) == :dreamland
      assert Stage.from_id(0x8) == :fountain_of_dreams
      assert Stage.from_id(0x6) == :yoshis_story
      assert Stage.from_id(0x1D) == :random_stage

      assert Stage.from_external(0x03) == :pokemon_stadium
      assert Stage.from_external(0x08) == :yoshis_story
      assert Stage.from_external(0x02) == :fountain_of_dreams
      assert Stage.from_external(0x1F) == :battlefield
      assert Stage.from_external(0x20) == :final_destination
      assert Stage.from_external(0x1C) == :dreamland
      # Unknown external IDs -> :no_stage, matching Python's to_internal_stage
      assert Stage.from_external(0x77) == :no_stage
      assert Stage.to_external(:battlefield) == 0x1F
      assert Stage.to_external(:random_stage) == nil
    end

    test "Action IDs" do
      assert Action.from_id(0x0E) == :standing
      assert Action.from_id(0x18) == :knee_bend
      assert Action.from_id(0xEC) == :airdodge
      assert Action.from_id(0xFD) == :edge_hanging
      assert Action.to_id(:dead_down) == 0x0
      assert Action.to_id(:landing_special) == 0x2B
      assert Action.to_id(:kirby_stone_unforming) == 0x18D
      assert_raise KeyError, fn -> Action.to_id(:not_an_action) end
    end

    test "Action alias behavior matches Python Enum aliasing" do
      # 0x168: DOWN_B_GROUND_START defined first -> canonical
      assert Action.from_id(0x168) == :down_b_ground_start
      assert Action.to_id(:sword_dance_2_mid_air) == 0x168
      # 0x15E: SWORD_DANCE_2_HIGH defined before FOX_ILLUSION_START
      assert Action.from_id(0x15E) == :sword_dance_2_high
      assert Action.to_id(:fox_illusion_start) == 0x15E
      # 0x170: SHINE_RELEASE_AIR defined before UP_B_AIR
      assert Action.from_id(0x170) == :shine_release_air
      assert Action.to_id(:up_b_air) == 0x170
      # 0x174: NESS_SHEILD_START defined before NESS_SHEILD
      assert Action.from_id(0x174) == :ness_sheild_start
      assert Action.to_id(:ness_sheild) == 0x174
    end

    test "ProjectileType IDs" do
      assert ProjectileType.from_id(0x36) == :fox_laser
      assert ProjectileType.from_id(0x37) == :falco_laser
      assert ProjectileType.from_id(0xD2) == :shy_guy
      assert ProjectileType.to_id(:bob_omb) == 0x06
      assert ProjectileType.to_id(:turnip) == 0x63
      assert ProjectileType.to_id(:kirby_yoshi_tongue) == 0x9D
    end

    test "Menu, SubMenu, ControllerStatus, AttackState IDs" do
      assert Menu.from_id(0xFF) == :unknown_menu
      assert Menu.to_id(:slippi_online_css) == 6
      assert SubMenu.from_id(0xFE) == :online_css
      assert SubMenu.to_id(:multiman_melee_submenu) == 33
      assert ControllerStatus.from_id(3) == :controller_unplugged
      assert AttackState.from_id(2) == :cooldown
    end

    test "name/1 is human readable" do
      assert Character.name(0x01) == "FOX"
      assert Action.name(0x0E) == "STANDING"
      assert Stage.name(0x19) == "FINAL_DESTINATION"
    end
  end

  describe "Button" do
    test "to_command_string returns exact Dolphin strings" do
      expected = %{
        a: "A",
        b: "B",
        x: "X",
        y: "Y",
        z: "Z",
        l: "L",
        r: "R",
        start: "START",
        d_up: "D_UP",
        d_down: "D_DOWN",
        d_left: "D_LEFT",
        d_right: "D_RIGHT",
        main: "MAIN",
        c: "C"
      }

      assert map_size(expected) == length(Button.buttons())

      for {atom, string} <- expected do
        assert Button.to_command_string(atom) == string
        assert Button.from_command_string(string) == atom
      end
    end

    test "unknown command string fallback" do
      assert Button.from_command_string("NOPE") == {:unknown, "NOPE"}
    end
  end

  describe "ControllerType" do
    test "Dolphin config strings roundtrip" do
      assert ControllerType.to_config_string(:standard) == "6"
      assert ControllerType.to_config_string(:gcn_adapter) == "12"
      assert ControllerType.to_config_string(:unplugged) == "0"

      for {atom, s} <- ControllerType.entries() do
        assert ControllerType.from_config_string(s) == atom
      end

      assert ControllerType.from_config_string("9") == {:unknown, "9"}
    end
  end
end
