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
  # RE-DERIVED for the mainline-beta build (2026-08-22 park-and-scan,
  # examples/memory_scan_css.exs): the classic 4-port cursor block
  # relocated INTACT by +0x17200 (Slippi allocations shifted the menu
  # heap); the classic inter-port stride 0xB80 is preserved exactly.
  # Verification: P1 tracks commanded cursor BIT-EXACTLY through the
  # MemoryWatcher path across 3 positions (tmp/mw_confirm.exs); P2/P3
  # delta-derived + read stable plausible parked coordinates
  # (-16.0,-2.5 / -1.0,-2.5); P4 delta-derived, weakly checked (x=0.0,
  # y unobserved). A second tracking copy of P1 lives at
  # 8112F278/8112F27C (render/secondary object — not used here).
  # Classic Ishiiruka-era block (stale on mainline): 81118DEC/81118DF0,
  # 8111826C/70, 811176EC/F0, 81116B6C/70.
  @css_cursor %{
    1 => {"8112FFEC", "8112FFF0"},
    2 => {"8112F46C", "8112F470"},
    3 => {"8112E8EC", "8112E8F0"},
    4 => {"8112DD6C", "8112DD70"}
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

  @doc """
  Decode the packed `:menu_state` u32 (address 0x80479D30) — the
  game's scene controller struct, four bytes big-endian:

      <<major, pending_major, previous_major, minor>>

  `major` is the scene family (0x02 = VS mode, 0x08 = Slippi online,
  0x01 = main menu, 0x28 = boot, special-melee majors per
  `Melee.Events.Menu`), `minor` the stage within it (0 = CSS, 1 = SSS,
  2 = in game, VS convention). `pending_major`/`previous_major` are
  the controller's transition registers — RAM-only signal the Slippi
  stream never carries: `pending != major` means a scene change is
  already committed but not yet landed.

  `stream_scene` is the same `(minor <<< 8) ||| major` u16 the Slippi
  menu event (0x3E) sends, so the decode plugs straight into
  `Melee.Events.Menu.scene_name/1` and every scene the stream parser
  already knows is a free cross-check.

  Layout evidence (2026-08-22): live read 0x02020200 at the offline VS
  CSS = {vs, vs, vs, css} — exactly the community scene-controller
  struct (Salvato RAM sheet / decomp). Byte-1/2 naming
  (pending/previous) follows that sheet; a live transition trace
  confirming which is which is still owed (MEMORY_WATCH_PROGRAM).
  """
  @spec decode_scene(non_neg_integer()) :: %{
          major: byte(),
          pending_major: byte(),
          previous_major: byte(),
          minor: byte(),
          stream_scene: non_neg_integer()
        }
  def decode_scene(u32) when is_integer(u32) and u32 >= 0 and u32 <= 0xFFFFFFFF do
    <<major, pending, previous, minor>> = <<u32::32>>

    %{
      major: major,
      pending_major: pending,
      previous_major: previous,
      minor: minor,
      stream_scene: Bitwise.bor(Bitwise.bsl(minor, 8), major)
    }
  end

  @doc """
  Human scene label for a packed `:menu_state` word — `decode_scene/1`
  piped through `Melee.Events.Menu.scene_name/1`.

  ## Examples

      iex> Melee.MemoryMap.scene_name(0x02020200)
      :character_select

      iex> Melee.MemoryMap.scene_name(0x02020202)
      :in_game

      iex> Melee.MemoryMap.scene_name(0x08080800)
      :slippi_online_css
  """
  def scene_name(u32) do
    u32 |> decode_scene() |> Map.fetch!(:stream_scene) |> Melee.Events.Menu.scene_name()
  end

  @doc """
  Classify a packed `:menu_state` word into a scene VIEW — the shape
  consumers reason about.

  Data definition:

      SceneView = {:settled, SceneName}
                | {:leaving, SceneName, SceneName}

    * `{:settled, name}` — `pending_major == major`: the scene is
      stable; `name` labels it (`Melee.Events.Menu.scene_name/1`
      taxonomy, so `{:unknown, scene}` marks unmapped scenes rather
      than crashing).
    * `{:leaving, from, to}` — `pending_major != major`: a scene
      change is committed in the engine but not yet landed. RAM-only
      signal; the Slippi stream never carries it. `to` is labeled at
      the pending family's ENTRY minor (0) — scene families enter at
      their first stage, but the true landing minor is the engine's
      call, so treat `to` as the FAMILY, not the exact screen.

  ## Examples

      iex> Melee.MemoryMap.scene_view(0x02020200)
      {:settled, :character_select}

      iex> Melee.MemoryMap.scene_view(0x01020100)
      {:leaving, :main_menu, :character_select}
  """
  @spec scene_view(non_neg_integer()) ::
          {:settled, term()} | {:leaving, term(), term()}
  def scene_view(u32) do
    decoded = decode_scene(u32)

    if decoded.pending_major == decoded.major do
      {:settled, Melee.Events.Menu.scene_name(decoded.stream_scene)}
    else
      {:leaving, Melee.Events.Menu.scene_name(decoded.stream_scene),
       Melee.Events.Menu.scene_name(decoded.pending_major)}
    end
  end

  @doc "menu/0 ++ canary/0 — the standing set for menu-era sessions."
  def menu_with_canary, do: canary() ++ menu()
end