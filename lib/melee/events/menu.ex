defmodule Melee.Events.Menu do
  @moduledoc """
  Parser for Slippi `menu_event` (0x3E) payloads.

  A functional translation of libmelee's
  `Console.__handle_slippstream_menu_event`. Menu enum wire values:
  character_select 0, stage_select 1, in_game 2, sudden_death 3,
  postgame_scores 4, main_menu 5, slippi_online_css 6, press_start 7,
  unknown 255 — see `Melee.Enums.Menu`.
  """

  alias Melee.{GameState, PlayerState, Position}

  # Menu enum wire values (enums.Menu)
  @character_select 0
  @stage_select 1
  @in_game 2
  @main_menu 5
  @slippi_online_css 6
  @press_start 7
  @unknown_menu 255

  # ControllerStatus.CONTROLLER_CPU
  @controller_cpu 1

  # SubMenu values used directly here
  @name_entry_submenu 0x05
  @online_css_submenu 0x00
  @unknown_submenu 0xFF

  @stage_no_stage 0

  @doc """
  Parse a menu event into an updated `Melee.GameState`.

  `bin` starts at the 0x3E command byte; all offsets are relative to it.
  """
  @spec parse(binary(), GameState.t()) :: GameState.t()
  def parse(bin, %GameState{} = gamestate) do
    scene = read_u16(bin, 0x1, 0xFFFF)

    {menu_state, reset_players?} =
      case scene do
        0x02 -> {@character_select, true}
        s when s in [0x0102, 0x0108] -> {@stage_select, true}
        0x0202 -> {@in_game, false}
        0x0001 -> {@main_menu, false}
        0x0008 -> {@slippi_online_css, true}
        0x0000 -> {@press_start, false}
        _ -> {@unknown_menu, false}
      end

    # Preserve the raw scene so an @unknown_menu stays identifiable (the
    # login screen vs the boot data-card dialog vs a genuinely novel
    # scene) — the blind A-then-B recovery exists precisely because this
    # value used to be thrown away. scene_name/1 labels the known ones.
    gamestate = %{gamestate | menu_state: menu_state, raw_scene: scene}

    gamestate =
      if reset_players? do
        %{gamestate | players: Map.new(1..4, &{&1, %PlayerState{}})}
      else
        gamestate
      end

    gamestate
    |> css_fields(bin)
    |> stage_select_fields(bin)
    |> common_fields(bin)
  end

  @doc """
  A human label for a raw scene id — the known scenes by name, and
  `{:unknown, scene}` for anything else, so callers (recovery logic,
  logs) can distinguish scenes that decode to `@unknown_menu`.

  The two @unknown scenes that show up in practice — the Slippi login
  screen and the boot "create game data?" dialog — do not yet have
  confirmed scene ids here: they only ever appeared live, where the
  bridge had already collapsed them to 255 and discarded the raw value.
  Now that `raw_scene` is preserved, the next occurrence of each logs
  its id (see the consumer in `Melee.MenuHelper`), at which point they
  earn a named clause below and stop being "unknown".

  ## Examples

      iex> Melee.Events.Menu.scene_name(0x0008)
      :slippi_online_css

      iex> Melee.Events.Menu.scene_name(0x0102)
      :stage_select

      iex> Melee.Events.Menu.scene_name(0x4242)
      {:unknown, 0x4242}

      iex> Melee.Events.Menu.scene_name(nil)
      {:unknown, nil}
  """
  @spec scene_name(integer() | nil) ::
          :character_select
          | :stage_select
          | :in_game
          | :main_menu
          | :slippi_online_css
          | :press_start
          | {:unknown, integer() | nil}
  def scene_name(0x02), do: :character_select
  def scene_name(s) when s in [0x0102, 0x0108], do: :stage_select
  def scene_name(0x0202), do: :in_game
  def scene_name(0x0001), do: :main_menu
  def scene_name(0x0008), do: :slippi_online_css
  def scene_name(0x0000), do: :press_start
  # Major scene 0x28: a transient boot splash. Observed 2026-08-14 on
  # both local builds (netplay-stable and ExiAI): appears for a fraction
  # of a second at boot, before the main menu, with no players and
  # regardless of memory-card config, and AUTO-ADVANCES to the main
  # menu with zero input (confirmed by idling on it: gone within two
  # polling steps). Needs no recovery — MenuHelper just waits it out.
  def scene_name(0x28), do: :boot_splash
  def scene_name(other), do: {:unknown, other}

  ## Character-select-screen fields (CSS and Slippi Online CSS)

  defp css_fields(%GameState{menu_state: menu} = gamestate, bin)
       when menu in [@character_select, @slippi_online_css] do
    players =
      Map.new(1..4, fn port ->
        i = port - 1
        player = Map.get(gamestate.players, port, %PlayerState{})

        character =
          case Melee.Enums.Character.from_css(read_u8(bin, 0x29 + i, nil)) do
            nil -> 0xFF
            char -> char
          end

        player = %{
          player
          | controller_status: read_u8(bin, 0x25 + i, 3),
            cursor: %Position{
              x: read_f32(bin, 0x3 + i * 8, 0.0),
              y: read_f32(bin, 0x7 + i * 8, 0.0)
            },
            character: character,
            character_selected: character,
            coin_down: read_u8(bin, 0x2D + i, 0) == 2
        }

        {port, player}
      end)

    # Wire semantics: raw byte 0 at 0x23 means the "ready to fight" banner
    # is up (Python's menuhelper presses START on == 0). Default 1 = not ready.
    %{gamestate | players: players, ready_to_start: read_u8(bin, 0x23, 1) == 0}
  end

  defp css_fields(gamestate, _bin), do: gamestate

  ## Stage-select-screen fields

  defp stage_select_fields(%GameState{menu_state: @stage_select} = gamestate, bin) do
    stage =
      case read_u8(bin, 0x24, nil) do
        nil -> @stage_no_stage
        raw -> if Melee.Enums.Stage.valid?(raw), do: raw, else: @stage_no_stage
      end

    cursor = %Position{x: read_f32(bin, 0x31, 0.0), y: read_f32(bin, 0x35, 0.0)}

    players = Map.new(gamestate.players, fn {port, p} -> {port, %{p | cursor: cursor}} end)
    %{gamestate | stage: stage, players: players}
  end

  defp stage_select_fields(gamestate, _bin), do: gamestate

  ## Fields common to all menu scenes

  defp common_fields(gamestate, bin) do
    submenu =
      case read_u8(bin, 0x3D, nil) do
        nil -> @unknown_submenu
        raw -> if Melee.Enums.SubMenu.valid?(raw), do: raw, else: @unknown_submenu
      end

    gamestate = %{
      gamestate
      | frame: read_i32(bin, 0x39, gamestate.frame),
        submenu: submenu,
        menu_selection: read_u8(bin, 0x3E, 0)
    }

    gamestate
    |> online_css_fields(bin)
    |> cpu_fields(bin)
  end

  defp online_css_fields(%GameState{menu_state: @slippi_online_css} = gamestate, bin) do
    gamestate =
      case read_u8(bin, 0x3F, nil) do
        nil ->
          gamestate

        costume ->
          players =
            Map.new(gamestate.players, fn {port, p} -> {port, %{p | costume: costume}} end)

          %{gamestate | players: players}
      end

    case read_u8(bin, 0x40, nil) do
      @name_entry_submenu -> %{gamestate | submenu: @name_entry_submenu}
      @online_css_submenu -> %{gamestate | submenu: @online_css_submenu}
      _ -> gamestate
    end
  end

  defp online_css_fields(gamestate, _bin), do: gamestate

  defp cpu_fields(gamestate, bin) do
    players =
      Map.new(gamestate.players, fn {port, player} ->
        i = port - 1

        player = %{
          player
          | cpu_level: read_u8(bin, 0x41 + i, player.cpu_level),
            is_holding_cpu_slider: read_u8(bin, 0x45 + i, 0) != 0
        }

        # cpu_level only means something for CPU-status controllers.
        player =
          if player.controller_status == @controller_cpu,
            do: player,
            else: %{player | cpu_level: 0}

        {port, player}
      end)

    %{gamestate | players: players}
  end

  ## Binary readers (out-of-range reads return the default)

  defp read_u8(bin, off, default) do
    case bin do
      <<_::binary-size(off), v, _::binary>> -> v
      _ -> default
    end
  end

  defp read_u16(bin, off, default) do
    case bin do
      <<_::binary-size(off), v::big-unsigned-16, _::binary>> -> v
      _ -> default
    end
  end

  defp read_i32(bin, off, default) do
    case bin do
      <<_::binary-size(off), v::big-signed-32, _::binary>> -> v
      _ -> default
    end
  end

  defp read_f32(bin, off, default) do
    case bin do
      <<_::binary-size(off), v::big-float-32, _::binary>> -> v
      _ -> default
    end
  end
end
