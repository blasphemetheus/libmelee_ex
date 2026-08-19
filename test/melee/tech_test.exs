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
end
