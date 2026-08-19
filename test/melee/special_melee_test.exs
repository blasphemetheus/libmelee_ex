defmodule Melee.SpecialMeleeTest do
  use ExUnit.Case, async: true

  alias Melee.Events.Menu

  # The Special Melee scene majors, measured one fresh session per menu
  # row (2026-08-18). Each mode's scene word follows the VS convention:
  # (minor <<< 8) ||| major with minor 0 = CSS, 1 = SSS, 2 = in game.
  @majors %{
    camera: 0x0A,
    stamina: 0x1F,
    super_sudden_death: 0x10,
    giant: 0x1E,
    tiny: 0x1D,
    invisible: 0x11,
    fixed_camera: 0x2A,
    single_button: 0x2C,
    lightning: 0x13,
    slo_mo: 0x12
  }

  test "special melee scenes classify by minor like VS mode" do
    for {mode, major} <- @majors do
      assert Menu.scene_name(major) == {:special_melee_css, mode}
      assert Menu.scene_name(0x100 + major) == {:special_melee_sss, mode}
      assert Menu.scene_name(0x200 + major) == {:special_melee_game, mode}
    end
  end

  test "menu events in special scenes produce navigable menu states" do
    # A minimal menu event: cmd byte + u16 scene. The classifier is
    # what MenuHelper keys navigation on.
    for {_mode, major} <- @majors do
      css = Menu.parse(<<0x3E, major::16-big, 0::size(600)-unit(8)>>, %Melee.GameState{})
      assert css.menu_state == 0
      sss = Menu.parse(<<0x3E, 0x100 + major::16-big, 0::size(600)-unit(8)>>, %Melee.GameState{})
      assert sss.menu_state == 1
      game = Menu.parse(<<0x3E, 0x200 + major::16-big, 0::size(600)-unit(8)>>, %Melee.GameState{})
      assert game.menu_state == 2
    end
  end
end
