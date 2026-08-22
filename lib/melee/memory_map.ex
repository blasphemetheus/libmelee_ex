defmodule Melee.MemoryMap do
  @moduledoc """
  Named RAM addresses for `Melee.MemoryWatcher` — NTSC 1.02 only.

  Provenance: classic libmelee's `melee/locations.csv` (the pre-Slippi,
  MemoryWatcher-era address book that drove SmashBot's menus and
  gamestate for years — commit `a086ea6~1` of altf4/libmelee), which in
  turn derives from the community SSBM RAM data sheet (Salvato,
  achilles et al.). Addresses are Dolphin MemoryWatcher lines: bare hex
  (`00479D30` ≡ 0x80479D30 in-game) or space-separated pointer chains
  (`004A0BC0 2` = Read_U32(Read_U32(0x804A0BC0) + 2)).

  Every read is a u32; float fields (cursors) decode via
  `MemoryWatcher.get_f32/2`. `coin_down` reads 2 when the coin is
  placed (classic semantics, matching `Melee.Events.Menu`).

  Usage:

      Melee.Dolphin.launch(
        ...,
        memory_watch: Melee.MemoryMap.menu()
      )

      Melee.MemoryWatcher.get_f32(w, :css_p1_cursor_x)

  Version guard: these are NTSC 1.02 (GALE01 rev 2) offsets — the only
  version this project runs. Do not use against PAL/other revisions.
  """

  # Addresses are 0x80-prefixed VIRTUAL addresses: the classic CSV's
  # bare offsets ("004D5F90") relied on Ishiiruka-era masking; the
  # mainline build's Memory::Read_U32 needs the full virtual form
  # (verified live 2026-08-22 — bare offsets produced ZERO traffic,
  # 80-prefixed streamed).
  @css_cursor %{
    1 => {"81118DEC", "81118DF0"},
    2 => {"8111826C", "81118270"},
    3 => {"811176EC", "811176F0"},
    4 => {"81116B6C", "81116B70"}
  }

  @css_block %{
    # {controller_status, character}
    1 => {"803F0E08", "803F0E0A"},
    2 => {"803F0E2C", "803F0E2E"},
    3 => {"803F0E50", "803F0E52"},
    4 => {"803F0E74", "803F0E76"}
  }

  @coin %{1 => "804A0BC0 2", 2 => "804A0BC4 2", 3 => "804A0BC8 2", 4 => "804A0BCC 2"}

  @doc """
  The menu/CSS watch set: scene state, menu frame counter, per-port CSS
  cursor (f32) / selected character / controller status / coin, the
  stage-select cursor, chosen stage, and the ready banner.

  This is the set that makes the online CSS observable again — the
  netplay-beta build streams NONE of it over the Slippi menu event
  (GOTCHA #101); RAM has it all.
  """
  def menu do
    per_port =
      Enum.flat_map(1..4, fn p ->
        {cx, cy} = @css_cursor[p]
        {status, char} = @css_block[p]

        [
          {:"css_p#{p}_cursor_x", cx},
          {:"css_p#{p}_cursor_y", cy},
          {:"css_p#{p}_status", status},
          {:"css_p#{p}_character", char},
          {:"css_p#{p}_coin", @coin[p]}
        ]
      end)

    [
      menu_state: "80479D30",
      menu_frame: "80479D60",
      stage: "804D6CAD",
      ready_to_start: "804D6CF2",
      sss_cursor_x: "80BDA810 28 38",
      sss_cursor_y: "80BDA810 28 3C"
    ] ++ per_port
  end

  @doc """
  Constantly-ticking canary (the game's RNG seed): traffic on this
  watch proves frames are advancing — a free liveness signal.
  """
  def canary, do: [rng_seed: "804D5F90"]

  @doc "menu/0 ++ canary/0 — the standing set for menu-era sessions."
  def menu_with_canary, do: canary() ++ menu()
end