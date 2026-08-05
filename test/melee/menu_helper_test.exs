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
      gs(menu_state: @character_select, frame: frame, players: %{1 => player(Keyword.merge(base, player_attrs))})
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
      {_state, wrote} = step_frame(state, gamestate, pid, path, base_opts(cpu_level: 3, autostart: true))
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

      {_state, wrote} = step_frame(state, gamestate, pid, path, base_opts(connect_code: "FOX#123"))

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
