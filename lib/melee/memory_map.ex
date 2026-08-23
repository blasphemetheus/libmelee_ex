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
  `MemoryWatcher.get_f32/2`. `css_pN_selected` reads the port's
  locked-in EXTERNAL character id, or `0x21` (33) when no character is
  selected — decode with `css_selected/1`.

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

  # SELECTED character per port (2026-08-22c toggle experiment,
  # tmp/mw_select_toggle.exs + tmp/mw_stride.exs): u32 = the port's
  # locked-in EXTERNAL character id, 0x21 = none. Flips on A-select and
  # back on B-deselect (visually verified: coin placed/lifted on
  # screenshots); hovering does NOT touch it, so it is the true
  # coin-down signal the stream lost on mainline (GOTCHA #101 + its
  # offline sibling). P1 verified with fox (0x21->0x02), P2 with falco
  # (0x21->0x14), both also read through the live MemoryWatcher path;
  # P3/P4 stride-derived (stride 8). A second parallel copy lives at
  # +0x54 (804320E0/E8/F0/F8) — same values, unused here. Classic
  # provenance: the 0x8043208F byte family (this u32's low byte);
  # static region, survived mainline intact like 803F0Exx. The classic
  # coin pointer chain (804A0BC0 2) is DEAD on mainline — stale
  # pointer.
  @css_selected %{
    1 => "8043208C",
    2 => "80432094",
    3 => "8043209C",
    4 => "804320A4"
  }

  @css_selected_none 0x21

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
          {:"css_p#{p}_selected", @css_selected[p]}
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

  # IN-GAME player statics (classic locations.csv block, base
  # 0x80453080, inter-player stride 0xE90) + the entity pointer at
  # base+0xB0 (0x80453130 for p1) whose chase reaches the action
  # fields. VERIFIED LIVE on mainline 2026-08-22c (tmp/mw_quartet.exs,
  # solo fox-vs-cpu game on FD): x/y/action bit-exact against the
  # Slippi stream row-wise; percent decodes as raw >> 16, stock as
  # raw >> 24. The whole classic static family survived mainline
  # (803F0Exx, 8043208C, and this block).
  @player_base %{1 => 0x80453080, 2 => 0x80453F10, 3 => 0x80454DA0, 4 => 0x80455C30}

  @doc """
  The in-game watch set: per-port position/percent/stock/facing
  (direct static reads) and action/action_frame (pointer chase through
  the entity at base+0xB0), plus the global frame counter and RNG
  seed.

  Decodings: x/y/facing via `MemoryWatcher.get_f32/2`; `percent` =
  raw `>>> 16`; `stock` = raw `>>> 24`; `action`/`action_frame` raw
  (action_frame is an f32 in the entity struct — use get_f32).

  The frame counter (0x80479D60, same word `menu_frame` reads) relates
  to Slippi frame stamps as `ram_frame = slippi_frame + 123` — the
  quartet run measured exactly +123 on all 900 arrival rows (the
  Slippi preamble starts at -123), which doubles as the per-session
  delay probe: any drift from +123 at arrival is pipeline lag.
  """
  def game do
    per_port =
      Enum.flat_map(1..4, fn p ->
        base = @player_base[p]
        entity = hex(base + 0xB0)

        [
          {:"p#{p}_x", hex(base + 0x10)},
          {:"p#{p}_y", hex(base + 0x14)},
          {:"p#{p}_facing", hex(base + 0x40)},
          {:"p#{p}_percent", hex(base + 0x60)},
          {:"p#{p}_stock", hex(base + 0x8E)},
          {:"p#{p}_action", entity <> " 70"},
          {:"p#{p}_action_frame", entity <> " 8F4"}
        ]
      end)

    [game_frame: "80479D60"] ++ canary() ++ per_port
  end

  defp hex(addr), do: addr |> Integer.to_string(16) |> String.upcase()

  # Direct-code typed buffer (2026-08-23 hunt, tmp/mw_codebuf4.exs):
  # the online Name Entry keyboard's text lives at 0x804A0740 —
  # STATIC (same address across boots; zeros only when the keyboard
  # scene is absent). Layout: 3 bytes per character — an SJIS-fullwidth
  # pair (A-Z 0x8260.., 0-9 0x824F.., '#' 0x8194) + a 0x00 pad —
  # NUL-terminated. A connect code is at most 8 chars = 24 bytes =
  # 6 u32 watch words. First keystroke REPLACES an autofilled field.
  @direct_code_base 0x804A0740
  @direct_code_words 6

  @doc """
  Watch set for the direct-code typed buffer: #{@direct_code_words}
  u32 words at 0x804A0740 (`:code_buf_0`..). Feed the read words to
  `decode_direct_code/1` to recover the typed string — the readback
  that lets a session VERIFY the entered connect code before
  confirming (the last blind menu, closed 2026-08-23).
  """
  def direct_code do
    for i <- 0..(@direct_code_words - 1) do
      {:"code_buf_#{i}", hex(@direct_code_base + i * 4)}
    end
  end

  @doc """
  Decode the `direct_code/0` watch words (in order) to the typed
  string. Total: unknown/unread words halt the decode at that point;
  unmappable pairs decode as `"?"`.

      iex> Melee.MemoryMap.decode_direct_code([0x82600000])
      "A"

      iex> Melee.MemoryMap.decode_direct_code([0x82640082, 0x77000000])
      "EX"
  """
  @spec decode_direct_code([non_neg_integer() | term()]) :: String.t()
  def decode_direct_code(words) do
    words
    |> Enum.take_while(&is_integer/1)
    |> Enum.flat_map(fn u32 ->
      bin = <<u32::32>>
      for <<b <- bin>>, do: b
    end)
    |> Enum.chunk_every(3, 3, :discard)
    |> Enum.reduce_while("", fn
      [0x82, lo | _], acc when lo >= 0x60 and lo <= 0x79 -> {:cont, acc <> <<?A + (lo - 0x60)>>}
      [0x82, lo | _], acc when lo >= 0x4F and lo <= 0x58 -> {:cont, acc <> <<?0 + (lo - 0x4F)>>}
      [0x81, 0x94 | _], acc -> {:cont, acc <> "#"}
      [0x00 | _], acc -> {:halt, acc}
      _partial_or_unknown, acc -> {:cont, acc <> "?"}
    end)
  end

  @doc "Decode a `:pN_percent` u32 read: the damage value."
  @spec percent(non_neg_integer()) :: non_neg_integer()
  def percent(raw), do: Bitwise.bsr(raw, 16)

  @doc "Decode a `:pN_stock` u32 read: stocks remaining."
  @spec stock(non_neg_integer()) :: non_neg_integer()
  def stock(raw), do: Bitwise.bsr(raw, 24)

  @doc """
  Decode a `:css_pN_selected` u32: `:none` while the port's coin is in
  hand (or the port is empty), `{:character, game_external_id}` once
  it is placed. The id is the GAME-external scheme (Slippi/engine:
  fox = 2, falco = 20 — NOT the CSS-grid ids `from_css/1` reads);
  convert with `Melee.Enums.Character.from_game_external/1`. The
  `0x21` sentinel is 33 = one past the 33-entry external roster. The
  RAM replacement for the stream's dead `coin_down` (GOTCHA #101):
  selection is exactly `value != 0x21`.
  """
  @spec css_selected(non_neg_integer()) :: :none | {:character, byte()}
  def css_selected(@css_selected_none), do: :none
  def css_selected(id) when is_integer(id) and id >= 0 and id <= 0xFF, do: {:character, id}

  @doc """
  Overlay RAM CSS observations from a `MemoryWatcher.snapshot/1` map
  onto a menu-scene `Melee.GameState` — the merge that makes a CSS the
  stream lies about (GOTCHA #101 online; dead `coin_down` offline)
  observable again. Pure and strictly additive: only fields the
  watcher has actually observed are substituted; an empty snapshot
  returns the gamestate unchanged. The CALLER decides when to apply it
  (character-select scenes only — the RAM cursor block means nothing
  elsewhere).

  Per port: cursor x/y (both must decode to finite f32s),
  `controller_status` (top byte), `character` (hover byte via
  `from_css/1`), and from the selected word: `coin_down` plus
  `character`/`character_selected` (via `from_game_external/1`) when a
  coin is placed — RAM distinguishes hover from lock, which the stream
  wire byte never did. Top-level: `ready_to_start` (byte 0 = banner
  up, mirroring the stream's semantics).

  `fields: :static` (default `:all`) skips the CURSOR overlay: the
  cursor block lives on the menu HEAP (relocatable per scene family —
  the 08-22 park-and-scan derived it at the offline CSS only), while
  every other field is in the verified STATIC region (validated at
  the online CSS live 2026-08-23). Use `:static` at scenes where the
  cursor addresses are unproven; a stale heap address would overlay
  garbage coordinates.
  """
  @spec merge_css(Melee.GameState.t(), %{atom() => non_neg_integer()}, keyword()) ::
          Melee.GameState.t()
  def merge_css(%Melee.GameState{} = gamestate, snapshot, opts \\ []) when is_map(snapshot) do
    fields = Keyword.get(opts, :fields, :all)

    players =
      Map.new(gamestate.players, fn {port, player} ->
        {port, merge_css_player(player, port, snapshot, fields)}
      end)

    ready =
      case top_byte(snapshot[:ready_to_start]) do
        nil -> gamestate.ready_to_start
        byte -> byte == 0
      end

    %{gamestate | players: players, ready_to_start: ready}
  end

  defp merge_css_player(player, port, snapshot, fields) do
    hover = top_byte(snapshot[:"css_p#{port}_character"])
    hover_internal = hover && Melee.Enums.Character.from_css(hover)

    player
    |> merge_cursor(
      fields,
      finite_f32(snapshot[:"css_p#{port}_cursor_x"]),
      finite_f32(snapshot[:"css_p#{port}_cursor_y"])
    )
    |> merge_field(:controller_status, top_byte(snapshot[:"css_p#{port}_status"]))
    |> merge_field(:character, hover_internal)
    |> merge_selected(snapshot[:"css_p#{port}_selected"])
  end

  defp merge_cursor(player, :all, x, y) when is_float(x) and is_float(y),
    do: %{player | cursor: %Melee.Position{x: x, y: y}}

  defp merge_cursor(player, _fields, _x, _y), do: player

  defp merge_field(player, _key, nil), do: player
  defp merge_field(player, key, value), do: Map.put(player, key, value)

  defp merge_selected(player, raw) when not is_integer(raw) or raw > 0xFF, do: player

  defp merge_selected(player, raw) do
    case css_selected(raw) do
      :none ->
        %{player | coin_down: false}

      {:character, ext} ->
        player = %{player | coin_down: true}

        case Melee.Enums.Character.from_game_external(ext) do
          nil -> player
          internal -> %{player | character: internal, character_selected: internal}
        end
    end
  end

  defp top_byte(nil), do: nil
  defp top_byte(u32) when is_integer(u32), do: Bitwise.bsr(u32, 24)

  defp finite_f32(nil), do: nil

  defp finite_f32(u32) when is_integer(u32) do
    case <<u32::32>> do
      <<f::float-big-32>> -> f
      _ -> nil
    end
  end

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