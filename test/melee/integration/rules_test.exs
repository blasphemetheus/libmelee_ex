defmodule Melee.Integration.RulesTest do
  use ExUnit.Case

  @moduledoc """
  Custom Rules through the public API: `Melee.Match.play/2` with
  `rules:` sets stock count, Stock Time Limit and Team Attack on the
  way to the match, and the game's own record proves it — stocks and
  timer straight from GAME_START, and Team Attack BEHAVIORALLY: the
  same ally-shine script deals damage with `team_attack: true` and none
  without, which is what pins byte 0x7 bit 3 as the Team Attack flag
  rather than a coincidental toggle.

      MELEE_DOLPHIN_PATH=~/.local/share/slippi/exi-ai-flush/dolphin-emu-headless \\
      MELEE_ISO_PATH=~/isos/melee.iso \\
      mix test --only dolphin_rules
  """

  alias Melee.{Controller, GameState, Match, Session}

  @moduletag :dolphin
  @moduletag :dolphin_rules
  @moduletag timeout: 600_000

  @home Path.join(System.tmp_dir!(), "libmelee_ex_rules_it")

  setup_all do
    path = System.get_env("MELEE_DOLPHIN_PATH")
    iso = System.get_env("MELEE_ISO_PATH")

    if path == nil or iso == nil do
      {:ok, skip: "set MELEE_DOLPHIN_PATH and MELEE_ISO_PATH"}
    else
      {:ok, path: Path.expand(path), iso: Path.expand(iso)}
    end
  end

  test "rules: sets stocks and timer, and persists within the session", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      {:ok, session} = start_session(ctx, "settings", 51_601)
      on_exit(fn -> safe_stop(session) end)

      {:ok, first} =
        Match.play(session,
          rules: [stock: 1, time_limit: 5, team_attack: true],
          p1: [character: :fox],
          p2: [character: :falco],
          stage: :final_destination
        )

      assert GameState.in_game?(first)
      assert first.players[1].stock == 1
      assert first.players[2].stock == 1
      assert first.timer == 300
      assert first.is_team_attack
      assert first.pause_enabled

      # Values are counted open-loop from fresh-session defaults, so a
      # second play may not ask for rules mid-session — the flow
      # refuses at the CSS instead of silently double-applying taps.
      {:ok, _} = Match.quit(session, Session.controller(session, 1), timeout_frames: 1_200)

      assert {:error, :rules_need_fresh_menu} =
               Match.play(session,
                 rules: [stock: 2],
                 p1: [character: :fox],
                 p2: [character: :falco],
                 stage: :final_destination
               )

      IO.puts("\n[dolphin] rules: stock=1 timer=300s team_attack=true from GAME_START")
      assert :ok = Session.stop(session)
    end
  end

  test "team_attack: true is ally damage ON — and OFF is really off", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      # Same script both runs: p1 chases its ally p2 and mashes shine
      # on contact. Only the rules differ, so damage on p2 can only be
      # the Team Attack setting (p3 idles far away on the other team).
      on_pct = ally_damage_run(ctx, true, 51_603)
      off_pct = ally_damage_run(ctx, false, 51_605)
      IO.puts("\n[dolphin] team attack: ally damage ON=#{on_pct}% OFF=#{off_pct}%")

      assert on_pct > 0.0, "ally attack dealt no damage with team_attack: true"
      assert off_pct == 0.0, "ally took #{off_pct}% with team attack OFF"
    end
  end

  test "pause: false disables the pause — and with it the LRAS quit", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      {:ok, session} = start_session(ctx, "pause", 51_607)
      on_exit(fn -> safe_stop(session) end)

      {:ok, first} =
        Match.play(session,
          rules: [pause: false],
          p1: [character: :fox],
          p2: [character: :falco],
          stage: :final_destination
        )

      assert GameState.in_game?(first)
      refute first.pause_enabled

      # The quit-out rides the pause menu, so a pause-disabled game
      # cannot be LRAS-quit — the documented trade-off of pause: false.
      assert {:error, :timeout} =
               Match.quit(session, Session.controller(session, 1), timeout_frames: 400)

      IO.puts("\n[dolphin] pause: false — pause_enabled=false, LRAS quit refused as expected")
      safe_stop(session)
    end
  end

  test "items: a Poke-Ball-only match spawns poke balls and nothing else", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      {:ok, session} = start_session(ctx, "items", 51_609)
      on_exit(fn -> safe_stop(session) end)

      {:ok, first} =
        Match.play(session,
          rules: [item_frequency: :very_high, items: [:poke_ball]],
          p1: [character: :fox],
          p2: [character: :falco],
          stage: :final_destination
        )

      assert GameState.in_game?(first)
      assert first.item_frequency == 4
      # Bit index == item id: containers 0-3 (not in the switch) plus
      # the poke ball (0x22) stay set, every switchable id 4..0x21 is
      # cleared — and the UNUSED bits 35-39 keep their all-ones
      # default (the mask starts 0xFFFFFFFFFF).
      assert first.item_bitfield == 0xFC_0000_000F

      types = collect_item_types(session, first, MapSet.new(), 2_500)
      poke_ball = Melee.Enums.ProjectileType.to_id(:poke_ball)

      assert poke_ball in types, "no poke ball spawned: #{inspect(Enum.sort(types))}"

      # Nothing else from the switchable block may spawn — containers
      # (0-3) and whatever they release aside, every id in 4..0x21 was
      # toggled off.
      illegal = Enum.filter(types, &(&1 in 4..0x21))
      assert illegal == [], "disabled items spawned: #{inspect(illegal)}"

      IO.puts("\n[dolphin] items: poke-ball-only, spawned types #{inspect(Enum.sort(types))}")
      safe_stop(session)
    end
  end

  test "boot_rules: the match starts pre-configured with ZERO menu taps", ctx do
    if ctx[:skip] do
      IO.puts("\n[dolphin] skipped: #{ctx.skip}")
    else
      # Boot-default rules via gecko writes over the template at
      # 0x803D4A48 — the same words Slippi's General Codes force to
      # tournament standard (which is also why card-saved rules never
      # survive boot; see docs/melee-menus.md). No rules: pass, no
      # Custom Rules navigation: the match starts already configured.
      home = Path.join(System.tmp_dir!(), "libmelee_ex_rules_it_boot")
      File.rm_rf!(home)

      {:ok, session} =
        Session.start_link(
          path: ctx.path,
          iso_path: ctx.iso,
          home: home,
          slippi_port: 51_611,
          headless: true,
          gfx_backend: "Null",
          blocking_input: true,
          boot_rules: [stock: 1, time_limit: 5, team_attack: false],
          ports: [1, 2],
          console: [polling_mode: true, polling_timeout: 100]
        )

      on_exit(fn -> safe_stop(session) end)

      {:ok, first} =
        Match.play(session,
          p1: [character: :fox],
          p2: [character: :falco],
          stage: :final_destination
        )

      assert GameState.in_game?(first)
      assert first.players[1].stock == 1
      assert first.players[2].stock == 1
      assert first.timer == 300
      refute first.is_team_attack
      assert first.pause_enabled

      IO.puts("\n[dolphin] boot_rules: stock=1 timer=300s ta=off with zero menu taps")
      safe_stop(session)
    end
  end

  defp collect_item_types(_session, _gamestate, types, 0), do: types

  defp collect_item_types(session, gamestate, types, frames_left) do
    types =
      if GameState.in_game?(gamestate),
        do: Enum.reduce(gamestate.projectiles, types, &MapSet.put(&2, &1.type)),
        else: types

    case Session.step(session) do
      {:ok, next} -> collect_item_types(session, next, types, frames_left - 1)
      nil -> collect_item_types(session, gamestate, types, frames_left - 1)
      {:error, _} -> types
    end
  end

  defp ally_damage_run(ctx, team_attack?, slippi_port) do
    name = if team_attack?, do: "ta_on", else: "ta_off"
    {:ok, session} = start_session(ctx, name, slippi_port, [1, 2, 3])

    {:ok, first} =
      Match.play(session,
        rules: [team_attack: team_attack?],
        teams: true,
        p1: [character: :fox],
        p2: [character: :fox],
        p3: [character: :marth, team: :blue],
        stage: :final_destination
      )

    assert GameState.in_game?(first)
    assert first.is_teams
    assert first.is_team_attack == team_attack?
    # p2 really is the ally — damage on it can only be the setting.
    assert first.players[1].team_id == first.players[2].team_id
    refute first.players[1].team_id == first.players[3].team_id

    controller = Session.controller(session, 1)
    pct = chase_and_shine(session, controller, first, 1_200)
    safe_stop(session)
    pct
  end

  # Steer p1 at its ally p2; mash down-B in range. Returns p2's percent
  # the moment it rises, or 0.0 if the budget runs out (the OFF run
  # spends the full budget shining through the ally).
  defp chase_and_shine(_session, _controller, gamestate, 0), do: gamestate.players[2].percent

  defp chase_and_shine(session, controller, gamestate, frames_left) do
    me = gamestate.players[1]
    ally = gamestate.players[2]

    cond do
      not GameState.in_game?(gamestate) ->
        Controller.release_all(controller)
        ally.percent

      ally.percent > 0.0 ->
        Controller.release_all(controller)
        ally.percent

      true ->
        dx = ally.position.x - me.position.x

        # Run at the ally and mash A in range: a dash attack / jab is a
        # NORMAL hitbox. (First attempt used shine — Fox's reflector
        # hit the ally for 5% even with Team Attack OFF, one of Melee's
        # known TA-OFF exceptions alongside grabs — so it cannot
        # discriminate the setting.)
        Controller.tilt_analog(controller, :main, if(dx > 0, do: 1.0, else: 0.0), 0.5)

        if abs(dx) < 9.0 and rem(frames_left, 4) in [0, 1],
          do: Controller.press_button(controller, :a),
          else: Controller.release_button(controller, :a)

        case Session.step(session) do
          {:ok, next} -> chase_and_shine(session, controller, next, frames_left - 1)
          nil -> chase_and_shine(session, controller, gamestate, frames_left - 1)
        end
    end
  end

  defp start_session(ctx, name, slippi_port, ports \\ [1, 2]) do
    home = "#{@home}_#{name}"
    File.rm_rf!(home)
    windowed? = System.get_env("MELEE_WINDOWED") == "1"

    Session.start_link(
      path: ctx.path,
      iso_path: ctx.iso,
      home: home,
      slippi_port: slippi_port,
      headless: not windowed?,
      gfx_backend: if(windowed?, do: "OGL", else: "Null"),
      blocking_input: true,
      ports: ports,
      console: [polling_mode: true, polling_timeout: 100]
    )
  end

  defp safe_stop(session) do
    Session.stop(session)
  catch
    _, _ -> :ok
  end
end
