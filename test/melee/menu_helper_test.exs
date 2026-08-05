defmodule Melee.MenuHelperTest do
  use ExUnit.Case, async: true

  alias Melee.{Controller, GameState, MenuHelper, PlayerState, Position}

  doctest Melee.MenuHelper

  @scratch System.tmp_dir!()

  # Menu wire values
  @character_select 0
  @stage_select 1
  @in_game 2
  @postgame_scores 4
  @main_menu 5
  @slippi_online_css 6
  @press_start 7

  @fox 0x01
  @fd 0x19

  @release_all "RELEASE A\nRELEASE B\nRELEASE X\nRELEASE Y\nRELEASE Z\n" <>
                 "RELEASE L\nRELEASE R\nRELEASE START\nRELEASE D_UP\n" <>
                 "RELEASE D_DOWN\nRELEASE D_LEFT\nRELEASE D_RIGHT\n" <>
                 "SET MAIN .5 .5\nSET C .5 .5\nSET L 0\nSET R 0\n"

  # A controller writing to a regular file: same code path as the fifo,
  # but the written command stream can be read back deterministically.
  defp file_controller(ctx) do
    path = Path.join(@scratch, "melee_menu_#{:erlang.phash2(ctx.test)}")
    File.rm(path)
    {:ok, pid} = Controller.start_link(pipe_path: path)
    :ok = Controller.connect(pid)
    {pid, path}
  end

  # Run one step and return {new_state, commands written this frame}.
  # Flushing (a GenServer call) serializes all the step's casts first.
  defp step_frame(state, gs, pid, path, opts) do
    before = byte_size(File.read!(path))
    state = MenuHelper.step(state, gs, pid, opts)
    :ok = Controller.flush(pid)
    content = File.read!(path)

    wrote =
      content
      |> binary_part(before, byte_size(content) - before)
      |> String.replace_suffix("FLUSH\n", "")

    {state, wrote}
  end

  defp set_main(x, y) do
    "SET MAIN #{Float.to_string(Controller.fix_analog_stick(x))} " <>
      "#{Float.to_string(Controller.fix_analog_stick(y))}\n"
  end

  defp gs(attrs), do: struct!(GameState, attrs)
  defp player(attrs), do: struct!(PlayerState, attrs)
  defp cursor(x, y), do: %Position{x: x * 1.0, y: y * 1.0}

  defp base_opts(extra \\ []), do: Keyword.merge([character: @fox, stage: @fd], extra)

  describe "press start scene" do
    test "START pulses on odd frames, release_all on even", ctx do
      {pid, path} = file_controller(ctx)
      state = MenuHelper.new()

      {state, wrote} =
        step_frame(state, gs(menu_state: @press_start, frame: 1), pid, path, base_opts())

      assert wrote == "PRESS START\n"

      {_state, wrote} =
        step_frame(state, gs(menu_state: @press_start, frame: 2), pid, path, base_opts())

      assert wrote == @release_all
    end

    test "with a connect code, still pulses START", ctx do
      {pid, path} = file_controller(ctx)

      {_state, wrote} =
        step_frame(
          MenuHelper.new(),
          gs(menu_state: @press_start, frame: 3),
          pid,
          path,
          base_opts(connect_code: "FOX#123")
        )

      assert wrote == "PRESS START\n"
    end
  end

  describe "character select" do
    # Fox external id 0x0A: row 1, column 1 -> target (-22.0, 11.5)

    test "cursor moves down toward Fox when too high", ctx do
      {pid, path} = file_controller(ctx)
      players = %{1 => player(cursor: cursor(-22, 25))}
      gamestate = gs(menu_state: @character_select, frame: 1, players: players)

      {_state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert wrote == "RELEASE START\nRELEASE A\n" <> set_main(0.5, 0.0)
    end

    test "cursor moves right toward Fox when too left", ctx do
      {pid, path} = file_controller(ctx)
      players = %{1 => player(cursor: cursor(-40, 11.5))}
      gamestate = gs(menu_state: @character_select, frame: 1, players: players)

      {_state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert wrote == "RELEASE START\nRELEASE A\n" <> set_main(1.0, 0.5)
    end

    test "presses A when the cursor is over the target character", ctx do
      {pid, path} = file_controller(ctx)
      players = %{1 => player(cursor: cursor(-22, 11.5))}
      gamestate = gs(menu_state: @character_select, frame: 1, players: players)

      {_state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert wrote == "RELEASE START\n" <> set_main(0.5, 0.5) <> "PRESS A\n"
    end

    test "releases all when our port has no player", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = gs(menu_state: @character_select, frame: 1, players: %{})

      {_state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert wrote == @release_all
    end
  end

  describe "ready to start" do
    defp selected_fox_gs(attrs) do
      players = %{1 => player(character: @fox, coin_down: true, cursor: cursor(-22, 11.5))}

      gs(Keyword.merge([menu_state: @character_select, players: players], attrs))
    end

    test "autostart presses START on odd frames once ready", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = selected_fox_gs(frame: 1, ready_to_start: true)

      {_state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(autostart: true))

      assert wrote == "PRESS START\n"
    end

    test "autostart releases all on even frames", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = selected_fox_gs(frame: 2, ready_to_start: true)

      {_state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(autostart: true))

      assert wrote == @release_all
    end

    test "no START without autostart", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = selected_fox_gs(frame: 1, ready_to_start: true)

      {_state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert wrote == @release_all
      refute wrote =~ "PRESS START"
    end
  end

  describe "stage select" do
    defp stage_gs(attrs) do
      cursor = Keyword.get(attrs, :cursor, cursor(0, 0))
      players = %{1 => player(cursor: cursor)}

      gs(
        Keyword.merge(
          [menu_state: @stage_select, players: players],
          Keyword.delete(attrs, :cursor)
        )
      )
    end

    test "cursor moves toward Final Destination's coordinates", ctx do
      {pid, path} = file_controller(ctx)
      # FD target is (6.7, -9); from (0, 0) we're too high -> move down
      gamestate = stage_gs(frame: 25, cursor: cursor(0, 0))

      {_state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(autostart: true))

      assert wrote == "RELEASE A\n" <> set_main(0.5, 0.0)
    end

    test "cursor moves right when left of the stage", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = stage_gs(frame: 25, cursor: cursor(0, -9))

      {_state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(autostart: true))

      assert wrote == "RELEASE A\n" <> set_main(1.0, 0.5)
    end

    test "presses A over the stage and records selection", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = stage_gs(frame: 25, cursor: cursor(6.7, -9))
      opts = base_opts(autostart: true, frozen_stadium: false)

      {state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, opts)

      assert wrote == set_main(0.5, 0.5) <> "PRESS A\n"
      assert state.stage_selected

      # After selection, subsequent frames just release
      {_state, wrote} = step_frame(state, stage_gs(frame: 26), pid, path, opts)
      assert wrote == @release_all
    end

    test "without autostart, does not navigate", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = stage_gs(frame: 25, cursor: cursor(0, 0))

      {_state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert wrote == @release_all
    end

    test "frame 0 resets stage_selected", ctx do
      {pid, path} = file_controller(ctx)
      state = %{MenuHelper.new() | stage_selected: true}
      gamestate = stage_gs(frame: 0, cursor: cursor(0, 0))

      {state, _wrote} =
        step_frame(state, gamestate, pid, path, base_opts(autostart: true))

      refute state.stage_selected
    end
  end

  describe "CPU level configuration" do
    # The state machine: walk to the HMN/CPU box, press A, walk to the
    # slider, grab it, drag to the wanted level, release. We simulate the
    # gamestate changes each press would cause.
    defp cpu_gs(frame, player_attrs) do
      base = [character: @fox, coin_down: true]

      gs(
        menu_state: @character_select,
        frame: frame,
        players: %{1 => player(Keyword.merge(base, player_attrs))}
      )
    end

    test "full flip-to-CPU and slider-drag sequence", ctx do
      {pid, path} = file_controller(ctx)
      opts = base_opts(cpu_level: 3)
      state = MenuHelper.new()

      # 1. Human status, wrong cpu_level: walk down to the HMN/CPU box
      gamestate = cpu_gs(2, controller_status: 0, cpu_level: 0, cursor: cursor(-32.2, 10))
      {state, wrote} = step_frame(state, gamestate, pid, path, opts)
      assert wrote == "RELEASE A\n" <> set_main(0.5, 0.0)

      # 2. Over the box, even frame: press A (flips HMN -> CPU)
      gamestate = cpu_gs(2, controller_status: 0, cpu_level: 0, cursor: cursor(-32.2, -2.2))
      {state, wrote} = step_frame(state, gamestate, pid, path, opts)
      assert wrote == "RELEASE A\nPRESS A\n"

      # 3. Over the box, odd frame: let go (the alternating press)
      gamestate = cpu_gs(3, controller_status: 0, cpu_level: 0, cursor: cursor(-32.2, -2.2))
      {state, wrote} = step_frame(state, gamestate, pid, path, opts)
      assert wrote == "RELEASE A\n" <> @release_all

      # 4. Now CPU status but wrong level: walk down toward the slider
      gamestate = cpu_gs(2, controller_status: 1, cpu_level: 1, cursor: cursor(-32.2, -2.2))
      {state, wrote} = step_frame(state, gamestate, pid, path, opts)
      assert wrote == set_main(0.5, 0.2)

      # 5. Over the slider, even frame: press A to grab it
      gamestate = cpu_gs(2, controller_status: 1, cpu_level: 1, cursor: cursor(-30.9, -15.12))
      {state, wrote} = step_frame(state, gamestate, pid, path, opts)
      assert wrote == "PRESS A\n"

      # 6. Holding the slider below the target level: drag right
      gamestate =
        cpu_gs(2,
          controller_status: 1,
          cpu_level: 1,
          is_holding_cpu_slider: true,
          cursor: cursor(-30.9, -15.12)
        )

      {state, wrote} = step_frame(state, gamestate, pid, path, opts)
      assert wrote == set_main(0.65, 0.5)

      # 7. Holding at the right level, even frame: press A to release it
      gamestate =
        cpu_gs(2,
          controller_status: 1,
          cpu_level: 3,
          is_holding_cpu_slider: true,
          cursor: cursor(-30.9, -15.12)
        )

      {state, wrote} = step_frame(state, gamestate, pid, path, opts)
      assert wrote == "PRESS A\n"

      # 8. Configured: CPU status, right level, slider released. The CPU
      # branch no longer triggers; with the character selected and coin
      # down we idle (no autostart) — the exact gate upstream code checks.
      gamestate =
        cpu_gs(3,
          controller_status: 1,
          cpu_level: 3,
          is_holding_cpu_slider: false,
          cursor: cursor(-30.9, -15.12)
        )

      {state, wrote} = step_frame(state, gamestate, pid, path, opts)
      assert wrote == @release_all

      # 9. ...and with autostart + ready banner, START is pressed
      gamestate =
        cpu_gs(3,
          controller_status: 1,
          cpu_level: 3,
          is_holding_cpu_slider: false,
          cursor: cursor(-30.9, -15.12)
        )

      gamestate = %{gamestate | ready_to_start: true}

      {_state, wrote} =
        step_frame(state, gamestate, pid, path, base_opts(cpu_level: 3, autostart: true))

      assert wrote == "PRESS START\n"
    end

    test "dragging left when the slider level is too high", ctx do
      {pid, path} = file_controller(ctx)

      gamestate =
        cpu_gs(2,
          controller_status: 1,
          cpu_level: 9,
          is_holding_cpu_slider: true,
          cursor: cursor(-30.9, -15.12)
        )

      {_state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(cpu_level: 3))

      assert wrote == set_main(0.35, 0.5)
    end
  end

  describe "direct connect code entry" do
    defp name_entry_gs(attrs) do
      gs(Keyword.merge([menu_state: @slippi_online_css, submenu: 0x05], attrs))
    end

    test "holds right until inputs are live", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = name_entry_gs(frame: 1, menu_selection: 45)

      {state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(connect_code: "FOX#123"))

      assert wrote == set_main(1.0, 0.5)
      refute state.inputs_live
    end

    test "releases all on even frames once live", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = name_entry_gs(frame: 2, menu_selection: 20)

      {state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(connect_code: "FOX#123"))

      assert wrote == @release_all
      assert state.inputs_live
    end

    test "presses A over the target letter and advances the index", ctx do
      {pid, path} = file_controller(ctx)
      # 'F' -> column 5 in "ABCDEFGHIJ" -> code 45 - 25 = 20
      gamestate = name_entry_gs(frame: 1, menu_selection: 20)

      {state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(connect_code: "FOX#123"))

      assert wrote == "PRESS A\n"
      assert state.name_tag_index == 1
    end

    test "moves off the bottom row (selection 57)", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = name_entry_gs(frame: 1, menu_selection: 57)

      {_state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(connect_code: "FOX#123"))

      assert wrote == set_main(0.5, 1.0)
    end

    test "presses START when the whole code has been entered", ctx do
      {pid, path} = file_controller(ctx)
      state = %{MenuHelper.new() | name_tag_index: 7, inputs_live: true}
      gamestate = name_entry_gs(frame: 1, menu_selection: 20)

      {_state, wrote} =
        step_frame(state, gamestate, pid, path, base_opts(connect_code: "FOX#123"))

      assert wrote == "PRESS START\n"
    end

    test "leaving name entry resets the entry state", ctx do
      {pid, path} = file_controller(ctx)
      state = %{MenuHelper.new() | name_tag_index: 4, inputs_live: true}
      players = %{1 => player(cursor: cursor(-22, 25))}

      gamestate =
        gs(menu_state: @character_select, submenu: 0xFF, frame: 1, players: players)

      {state, _wrote} = step_frame(state, gamestate, pid, path, base_opts())

      assert state.name_tag_index == 0
      refute state.inputs_live
    end
  end

  describe "main menu" do
    test "versus mode: presses A on the right selection", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = gs(menu_state: @main_menu, submenu: 0, menu_selection: 1, frame: 1)

      {_state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert wrote == "PRESS A\n"
    end

    test "versus mode: scrolls down otherwise", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = gs(menu_state: @main_menu, submenu: 0, menu_selection: 0, frame: 1)

      {_state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert wrote == set_main(0.5, 0.0)
    end

    test "with a connect code, navigates the online play submenu", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = gs(menu_state: @main_menu, submenu: 8, menu_selection: 2, frame: 1)

      {_state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(connect_code: "FOX#123"))

      assert wrote == "PRESS A\n"
    end

    test "backs out of unknown submenus with B", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = gs(menu_state: @main_menu, submenu: 4, menu_selection: 0, frame: 1)

      {_state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert wrote == "PRESS B\n"
    end
  end

  describe "postgame scores" do
    test "alternates pressing and releasing START", ctx do
      {pid, path} = file_controller(ctx)
      gamestate = gs(menu_state: @postgame_scores, frame: 1)
      state = MenuHelper.new()

      {state, wrote} = step_frame(state, gamestate, pid, path, base_opts())
      assert wrote == "PRESS START\n"

      # prev now has START held, so the next frame releases it
      {_state, wrote} = step_frame(state, gamestate, pid, path, base_opts())
      assert wrote == "RELEASE START\n"
    end
  end

  describe "in-game nametag: option parsing" do
    test "no :nametag leaves the flow untouched and picks a character", ctx do
      {pid, path} = file_controller(ctx)

      gamestate =
        gs(
          menu_state: @character_select,
          frame: 1,
          players: %{1 => player(character: @fox, cursor: cursor(0, 0), coin_down: true)}
        )

      {state, wrote} = step_frame(MenuHelper.new(), gamestate, pid, path, base_opts())

      assert state.nametag_phase == :waiting
      assert state.nametag_done == false
      # character selection, not the name box (which is far below at y ~ -18)
      refute wrote == ""
      assert state == MenuHelper.new()
    end

    test "an already-done flow falls through to character selection", ctx do
      {pid, path} = file_controller(ctx)
      state = %{MenuHelper.new() | nametag_done: true, nametag_phase: :done}

      gamestate =
        gs(
          menu_state: @character_select,
          frame: 1,
          players: %{1 => player(character: @fox, cursor: cursor(0, 0), coin_down: true)}
        )

      {new_state, _wrote} =
        step_frame(state, gamestate, pid, path, base_opts(nametag: "EXPH"))

      assert new_state.nametag_phase == :done
    end

    test "waits for a character on our panel before opening the name box", ctx do
      {pid, path} = file_controller(ctx)

      # 0xFF is an empty CSS panel: there is no name box to press A on.
      gamestate =
        gs(
          menu_state: @character_select,
          frame: 1,
          players: %{1 => player(character: 0xFF, cursor: cursor(0, 0), coin_down: false)}
        )

      {state, _wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(nametag: "EXPH"))

      # still :waiting, and nametag_frames never started counting
      assert state.nametag_phase == :waiting
      assert state.nametag_frames == 0
    end
  end

  describe "in-game nametag: phase transitions" do
    # The measured port-1 targets (see MenuHelper source).
    @name_box {-23.7, -18.62}
    # x is irrelevant for list rows: the open list pins the hand there.
    # Row 2 is NAME ENTRY when no tag is saved, the saved tag once one is.
    @row2_y -8.7

    defp css(cursor, extra \\ []) do
      gs(
        Keyword.merge(
          [
            menu_state: @character_select,
            frame: 1,
            players: %{1 => player(character: @fox, cursor: cursor, coin_down: true)}
          ],
          extra
        )
      )
    end

    test "moves down toward the name box when the cursor is above it", ctx do
      {pid, path} = file_controller(ctx)

      {state, wrote} =
        step_frame(MenuHelper.new(), css(cursor(-23, 0)), pid, path, base_opts(nametag: "EXPH"))

      # far away on y -> full downward tilt
      assert wrote =~ set_main(0.5, 0.0)
      assert state.nametag_phase == :name_box
      assert state.nametag_frames == 0
    end

    test "eases off the stick when it is close to the target", ctx do
      {pid, path} = file_controller(ctx)
      {_x, y} = @name_box

      {_state, wrote} =
        step_frame(
          MenuHelper.new(),
          css(cursor(-23.22, y + 2.0)),
          pid,
          path,
          base_opts(nametag: "EXPH")
        )

      assert wrote =~ set_main(0.5, 0.28)
    end

    test "on the name box, pulses A then advances to the list phase", ctx do
      {pid, path} = file_controller(ctx)
      {x, y} = @name_box
      on_box = css(cursor(x, y))
      state = MenuHelper.new()

      # first frames: A held
      {state, wrote} = step_frame(state, on_box, pid, path, base_opts(nametag: "EXPH"))
      assert wrote == set_main(0.5, 0.5) <> "PRESS A\n"
      assert state.nametag_frames == 1

      state =
        Enum.reduce(1..23, state, fn _i, state ->
          {state, _} = step_frame(state, on_box, pid, path, base_opts(nametag: "EXPH"))
          assert state.nametag_phase == :name_box
          state
        end)

      # frame 25: settle window is over, so we move on to the list
      {state, _wrote} = step_frame(state, on_box, pid, path, base_opts(nametag: "EXPH"))
      assert state.nametag_phase == :list
      assert state.nametag_frames == 0
    end

    test ":select presses A on the list's second row and finishes", ctx do
      {pid, path} = file_controller(ctx)
      # Row 2 holds the saved tag once one exists (NAME ENTRY is always
      # last), so both modes aim at the same y.
      on_row = css(cursor(-25.2, @row2_y))
      state = %{MenuHelper.new() | nametag_phase: :list}

      state =
        Enum.reduce(1..24, state, fn _i, state ->
          {state, _} = step_frame(state, on_row, pid, path, base_opts(nametag: "EXPH"))
          state
        end)

      assert state.nametag_phase == :list

      {state, _} = step_frame(state, on_row, pid, path, base_opts(nametag: "EXPH"))
      assert state.nametag_phase == :done
      assert state.nametag_done == true
    end

    test "the list is steered by y alone, never by x", ctx do
      {pid, path} = file_controller(ctx)
      state = %{MenuHelper.new() | nametag_phase: :list}

      # Wildly wrong x, correct y: the open list pins x, so we must not
      # try to steer it — we press A instead.
      {state, wrote} =
        step_frame(state, css(cursor(5.0, @row2_y)), pid, path, base_opts(nametag: "EXPH"))

      assert wrote == set_main(0.5, 0.5) <> "PRESS A\n"
      assert state.nametag_frames == 1
    end

    test "a row that is too low is approached with an eased upward tilt", ctx do
      {pid, path} = file_controller(ctx)
      state = %{MenuHelper.new() | nametag_phase: :list}

      {_state, wrote} =
        step_frame(
          state,
          css(cursor(-25.2, @row2_y - 2.4)),
          pid,
          path,
          base_opts(nametag: "EXPH", nametag_mode: :create)
        )

      assert wrote =~ set_main(0.5, 0.72)
    end

    test ":create types the tag on the keyboard and finishes when it closes", ctx do
      {pid, path} = file_controller(ctx)
      opts = base_opts(nametag: "EX", nametag_mode: :create)

      # submenu 18 / selection 45 is the name-entry keyboard
      keyboard = fn selection, frame ->
        gs(
          menu_state: @character_select,
          submenu: 18,
          menu_selection: selection,
          frame: frame,
          players: %{1 => player(character: @fox, cursor: cursor(0, 0), coin_down: false)}
        )
      end

      state = %{MenuHelper.new() | nametag_phase: :list}

      # frame 1 on selection 45: inputs are not live yet, so we nudge right
      {state, wrote} = step_frame(state, keyboard.(45, 1), pid, path, opts)
      assert state.nametag_phase == :typing
      assert wrote =~ set_main(1.0, 0.5)

      # 'E' lives at code 45 - 4*5 = 25; land on it and A is pressed
      {state, wrote} = step_frame(state, keyboard.(25, 1), pid, path, opts)
      assert wrote == "PRESS A\n"
      assert state.name_tag_index == 1

      # 'X' lives at 47 - 3*5 = 32
      {state, wrote} = step_frame(state, keyboard.(32, 3), pid, path, opts)
      assert wrote == "PRESS A\n"
      assert state.name_tag_index == 2

      # tag complete -> START confirms
      {state, wrote} = step_frame(state, keyboard.(32, 5), pid, path, opts)
      assert wrote == "PRESS START\n"
      refute state.nametag_done

      # keyboard gone -> the flow is finished
      {state, _wrote} = step_frame(state, css(cursor(0, 0)), pid, path, opts)
      assert state.nametag_phase == :done
      assert state.nametag_done == true
    end

    test "stays latched when the hovered character flickers back to 0xFF", ctx do
      {pid, path} = file_controller(ctx)
      opts = base_opts(nametag: "EXPH")

      # `character` at the CSS is whatever portrait the hand hovers, so it
      # drops back to 0xFF the moment the cursor leaves the grid. Once the
      # flow has started it must keep steering, not hand control back to
      # choose_character (which would fight it at the grid boundary).
      {state, _wrote} = step_frame(MenuHelper.new(), css(cursor(-23, 0)), pid, path, opts)
      assert state.nametag_phase == :name_box

      off_grid =
        css(cursor(-23, -5))
        |> Map.put(:players, %{
          1 => player(character: 0xFF, cursor: cursor(-23, -5), coin_down: false)
        })

      {state, wrote} = step_frame(state, off_grid, pid, path, opts)

      assert state.nametag_phase == :name_box
      # still heading down to the name box at y ~ -18.6
      assert wrote =~ set_main(0.5, 0.0)
    end

    test "a cursor that never arrives keeps the flow in its first phase", ctx do
      {pid, path} = file_controller(ctx)
      opts = base_opts(nametag: "EXPH")
      # The CSS start position, frozen: we must keep steering, never press.
      start = css(cursor(-31.0, -2.5))

      final =
        Enum.reduce(1..30, MenuHelper.new(), fn _i, state ->
          {state, _wrote} = step_frame(state, start, pid, path, opts)
          state
        end)

      assert final.nametag_phase == :name_box
      assert final.nametag_frames == 0
      refute final.nametag_done
    end
  end

  describe "in-game nametag: per-port coordinate math" do
    test "port 2's name box is one panel width to the right of port 1's", ctx do
      {pid, path} = file_controller(ctx)
      spacing = 15.82
      port2_box_x = -23.7 + spacing

      # Sitting exactly on PORT 1's box while driving port 2: we must
      # still be moving right, toward port 2's panel.
      gamestate =
        gs(
          menu_state: @character_select,
          frame: 1,
          players: %{
            2 => player(character: @fox, cursor: cursor(-23.7, -18.62), coin_down: true)
          }
        )

      {state, wrote} =
        step_frame(MenuHelper.new(), gamestate, pid, path, base_opts(nametag: "EXPH", port: 2))

      assert wrote =~ set_main(1.0, 0.5)
      assert state.nametag_frames == 0

      # ... and on port 2's box we press A instead
      gamestate2 =
        gs(
          menu_state: @character_select,
          frame: 1,
          players: %{
            2 => player(character: @fox, cursor: cursor(port2_box_x, -18.62), coin_down: true)
          }
        )

      {_state, wrote} =
        step_frame(MenuHelper.new(), gamestate2, pid, path, base_opts(nametag: "EXPH", port: 2))

      assert wrote == set_main(0.5, 0.5) <> "PRESS A\n"
    end

    test "a missing port releases everything and does nothing", ctx do
      {pid, path} = file_controller(ctx)
      state = %{MenuHelper.new() | nametag_phase: :list}

      gamestate =
        gs(menu_state: @character_select, frame: 1, players: %{1 => player(character: @fox)})

      {new_state, wrote} =
        step_frame(state, gamestate, pid, path, base_opts(nametag: "EXPH", port: 3))

      assert wrote == @release_all
      assert new_state == state
    end
  end

  describe "in game" do
    test "writes nothing and returns the state unchanged", ctx do
      {pid, path} = file_controller(ctx)
      state = MenuHelper.new()
      gamestate = gs(menu_state: @in_game, frame: 100)

      new_state = MenuHelper.step(state, gamestate, pid, base_opts())
      # a call serializes any pending casts before we read the file
      _ = Controller.current(pid)

      assert new_state == state
      assert File.read!(path) == ""
    end
  end
end
